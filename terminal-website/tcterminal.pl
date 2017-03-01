#!/usr/bin/env perl
use strict;
use warnings;
use Mojolicious::Lite;
use Mojo::JSON;
use Mojo::Log;
use LWP::UserAgent;
use Data::Dumper;
use Authen::Simple::ActiveDirectory;
use DBI;
use POSIX;
use Date::Calc qw/Today Date_to_Days Add_Delta_Days Day_of_Week Date_to_Time Add_Delta_DHMS Delta_Days Gmtime/;
use Mojolicious::Plugin::AccessLog;

# TODO: make an admin field for employees and allow setting admin badges there in manger
# These iButton IDs will get admin access on the terminals when scanned.
my @adminBadges = qw//;

# where android updates will be, used for getting the current version
my $updateDir = '/projects/timeclock/terminal-website/public/apk';


sub dbConnect { return DBI->connect_cached("DBI:mysql:time:db.host", "user", "pass"); }

#
# Used to store the terminals Android ID for lookup in any request.
#
hook before_routes => sub {
	my $s = shift;
	my ($id)      = $s->req->headers->user_agent =~ /\[.*? id:([\da-f]{16}) .*?\]/;
	my ($version) = $s->req->headers->user_agent =~ /\[.*? version:([\d\.\-]+) .*?\]/;
	my ($ip)      = $s->tx->remote_address;
	$s->stash(
		android_id       => uc($id   // "unknown"),
		terminal_version => $version // "unknown",
		terminal_ip      => $ip      // "0.0.0.0",
	);
};


#
#
#
plugin AccessLog => { 
	log    => '/var/log/timeclock/terminal_access.log',
	format => '%{%Y-%m-%d %H:%M:%S}t|%a|%B|%D|%m|%U|"%{User-Agent}i"',
};
 


#--------------------------------------------------------------------#
# 
#--------------------------------------------------------------------#
get '/punchFromPunchy/:empID' => [empID => qr/\d+/] => sub {
	my $s     = shift;
	my $db    = dbConnect();
	my $empID = $s->param("empID");

	my $emp = $db->selectrow_hashref("SELECT * FROM employees WHERE employee_id = ? AND active = TRUE", {}, $empID);
	return $s->render(json => { result => 'error' }) unless (defined($emp));

	# Only allowed to punch in or out if at least 1 minute has passed.
	my $recentPunch = $db->selectrow_arrayref("
		SELECT TIMESTAMPDIFF(SECOND, time, UTC_TIMESTAMP()) AS diff
		FROM punches
		WHERE 
			deleted = 0 AND
			time >= DATE_SUB(UTC_TIMESTAMP(), INTERVAL 1 DAY) AND
			employee_id = ?
		HAVING diff <= 60
		LIMIT 1
	", {}, $empID);

	my ($wasTardy);
	my $newStatus = $emp->{status};
	unless (defined($recentPunch)) {
		$newStatus ^= 1;
		$db->do("UPDATE employees SET status = ? WHERE employee_id = ?", {}, $newStatus, $empID);
		$db->do("
			INSERT INTO punches 
				(employee_id, terminal_id, time, in_out, fake, deleted, reason_id, modified_by, modified_on)
			VALUES (?, ?, UTC_TIMESTAMP(), ?, 0, 0, 0, 0, NULL)
		", {}, $empID, 0, $newStatus);

		# last_insert_id has been flaky
		my $punchID = $db->selectrow_arrayref("
			SELECT punch_id FROM punches WHERE employee_id = ? ORDER BY punch_id DESC LIMIT 1
		", {}, $empID)->[0];

		# Only the in punches will get flagged.
		if ($newStatus == 1) {
			# The tardy will be set here if needed.
			$wasTardy = checkIfTardy($s, $punchID);
		}
	}

	$s->render(json => {
		result => "ok",
		status => $newStatus,
		tardy  => $wasTardy,
	});
};


#--------------------------------------------------------------------#
# Punch
#--------------------------------------------------------------------#
get '/punch/:badge' => [badge => qr/[\da-f]{16}/i] => sub {
	my $s     = shift;
	my $badge = uc($s->param("badge"));
	my $db    = dbConnect();

	$s->app->log->info("[punch] got badge: " . $s->param("badge"));
	if ($badge ~~ @adminBadges) {
		$s->session(admin => 1);
		return $s->redirect_to("/admin");
	}

	my $emp = $db->selectrow_hashref("
		SELECT * FROM employees WHERE badge = ? AND active = TRUE
	", {}, $badge);

	unless (defined($emp)) {
		$s->flash(error => "Badge is not assigned to an employee");
		return $s->redirect_to("/error");
	}

	# only allowed to punch in or out if at least 1 minute has passed
	my $recentPunch = $db->selectrow_arrayref("
		SELECT TIMESTAMPDIFF(SECOND, time, UTC_TIMESTAMP()) AS diff
		FROM punches
		WHERE 
			deleted = 0 AND
			time >= DATE_SUB(UTC_TIMESTAMP(), INTERVAL 1 DAY) AND
			employee_id = ?
		HAVING diff <= 60
		LIMIT 1
	", {}, $emp->{employee_id});

	my ($wasTardy);
	unless (defined($recentPunch)) {
		my $terminalID = $db->selectrow_arrayref("
			SELECT terminal_id FROM terminals WHERE android_id = ?
		", {}, $s->stash("android_id"));
		$terminalID = defined($terminalID) ? $terminalID->[0] : 0;

		my $newStatus = $emp->{status} ^ 1;
		$db->do("
			UPDATE employees SET status = ? WHERE employee_id = ?
		", {}, $newStatus, $emp->{employee_id});

		$db->do("
			INSERT INTO punches 
				(employee_id, terminal_id, time, in_out, fake, deleted, reason_id, modified_by, modified_on)
			VALUES (?, ?, UTC_TIMESTAMP(), ?, 0, 0, 0, 0, NULL)
		", {}, $emp->{employee_id}, $terminalID, $newStatus);

		# last_insert_id has been flaky
		my $punchID = $db->selectrow_arrayref("
			SELECT punch_id FROM punches WHERE employee_id = ? ORDER BY punch_id DESC LIMIT 1
		", {}, $emp->{employee_id})->[0];

		# Only the in punches will get flagged.
		if ($newStatus == 1) {
			$wasTardy = checkIfTardy($s, $punchID);
		}

		$emp->{status} = $newStatus;
	}

	$s->stash(
		e             => $emp,
		tardy         => $wasTardy,
		dates         => $s->datesForPeriod($s->currentPeriod()),
		periodPunches => $s->periodPunches($emp->{employee_id}, $s->currentPeriod(), 1),
	);
} => "punch";


#
# Checks if $punchID is a tardy punch and marks it if it is. If the punch
# was already marked tardy it will NOT be cleared. Tardy checks are done
# to the second without any rounding. An in punch > 3 hours from their 
# start punch will be consider a lunch punch and will be tardy when at 
# lunch for >= 1 hour and 3 minutes.
#
sub checkIfTardy {
	my ($s, $punchID) = @_;
	my $db = dbConnect();

	my $empID = $db->selectrow_arrayref("
		SELECT employee_id FROM punches WHERE punch_id = ?
	", {}, $punchID)->[0];

	my $existing = $db->selectrow_arrayref("
		SELECT * FROM tardies WHERE punch_id = ? AND employee_id = ? AND deleted = false
	", {}, $punchID, $empID);
	if (defined($existing)) {
		$s->app->log->info("[tardy check] punch is already marked tardy");
		return 1;
	}

	my $emp = $db->selectrow_hashref("
		SELECT employees.*, locations.timezone
		FROM employees LEFT JOIN locations USING (location_id)
		WHERE employee_id = ? AND active = true
	", {}, $empID);

	# only the in (offending) punch gets flagged
	my $punch = $db->selectrow_hashref("
		SELECT CONVERT_TZ(time, 'UTC', ?) AS tz_time, employee_id
		FROM punches WHERE punch_id = ? AND deleted = false AND in_out = 1
	", {}, $emp->{timezone}, $punchID);
	unless (defined($punch)) {
		$s->app->log->info("[tardy check] not an in punch, not checking");
		return undef;
	}

	my ($y, $m, $d, $hour, $min, $sec) = $punch->{tz_time} =~ /(\d+)-(\d+)-(\d+) (\d+):(\d+):(\d+)/;
	my @weekDays = qw/sun mon tue wed thu fri sat sun/;
	my $dow = Day_of_Week($y, $m, $d);

	my $startTime = $emp->{"start_" . $weekDays[$dow]};
	unless ($startTime) {
		$s->app->log->info("[tardy check] no start time for the day, not checking");
		return undef;
	}

	my ($startH, $startM) = $startTime =~ /^(\d+):(\d+)/;

	# >= 3 minutes after start time is tardy
	# >= 1 hour and 3 minutes after lunch is tardy

	my $punchTS = Date_to_Time($y, $m, $d, $hour, $min, $sec);	
	my $startTS = Date_to_Time($y, $m, $d, $startH, $startM, 0);

	# Get the last out punch from today if there is one.
	my $lastOut = $db->selectrow_hashref("
		SELECT CONVERT_TZ(time, 'UTC', ?) AS tz_time 
		FROM punches 
		WHERE 
			employee_id = ?     AND
			in_out      = 0     AND
			deleted     = FALSE AND
			DATE(CONVERT_TZ(time, 'UTC', ?)) = DATE(?) AND
			CONVERT_TZ(time, 'UTC', ?) < ?
		ORDER BY time DESC LIMIT 1
	", {}, 
		$emp->{timezone}, 
		$emp->{employee_id}, 
		$emp->{timezone}, $punch->{tz_time},
		$emp->{timezone}, $punch->{tz_time}
	);

	my $lastOutTS = defined($lastOut) ? toTS($lastOut->{tz_time}) : undef;

	my $tardy = 0;
	# safe start punch for the day
	if ($punchTS < ($startTS + (60 * 3))) {
		$s->app->log->info("[tardy check] punch was on time, not tardy");
		return undef;
	}
	# Not their first punch, only check to see if they took too long of a lunch.
	elsif (defined($lastOutTS)) {
		# Only treat as a lunch punch if it's at least 4 hours after their start punch.
		if ($punchTS >= ($startTS + (4 * 60 * 60))) {
			# if lunch was >= 1 hour 3 minutes it's tardy
			if (($punchTS - $lastOutTS) >= 3780) {
				$s->app->log->info("[tardy check] lunch was too long, tardy");
				$tardy = 1;
			}
		}
		else {
			# Not a lunch punch and not the first punch of the day so ignore it.
		}
	}
	# Their first punch for the day.
	else {
		$s->app->log->info("[tardy check] first punch and late, tardy");
		$tardy = 1;
	}

	unless ($tardy == 1) {
		$s->app->log->info("[tardy check] got through all checks without tardy, punch_id: $punchID");
		return undef;
	}

	# Mark it tardy, Donnie.
	$db->do("
		INSERT INTO tardies (employee_id, punch_id, reason_id, deleted) 
		VALUES (?, ?, 1, 0)
	", {}, $empID, $punchID);

	$s->app->log->info("[tardy check] marked tardy, punch_id: $punchID");

	return 1;
}


#
# Converts a datetime string or full array to a timestamp. No time zone
# conversion is done.
#
sub toTS {
	my @dt = @_;
	unless (defined($dt[5])) {
		(@dt) = $dt[0] =~ /(\d+)-(\d+)-(\d+) (\d+):(\d+):(\d+)/;
	}
	return Date_to_Time(@dt);
}


#--------------------------------------------------------------------#
# Admin Interface
#--------------------------------------------------------------------#
group {

under '/admin' => sub {
	my $s = shift;
	return 1 if ($s->session("admin") == 1);
	$s->flash(error => "Not authorized");
	$s->redirect_to("/error");
	return undef;
};

get '/' =>  sub { return $_[0]->redirect_to("/admin/1"); }; # /admin
get '/:page' => [page => qr/\d+/] => sub { # /admin/:page
	my $s    = shift;
	my $page = $s->param("page");
	my $db   = dbConnect();

	my $startAt = ($s->param("page") - 1) * 18;
	my $total = $db->selectrow_arrayref("
		SELECT COUNT(*) FROM employees WHERE badge = '' AND active = 1
	")->[0];

	my $employees = $db->selectall_arrayref("
		SELECT * FROM employees 
		WHERE badge = '' AND active = 1 ORDER BY first_name, last_name
		LIMIT ?, 18
	", { Slice => {} }, $startAt);

	my $terminal = $db->selectrow_hashref("
		SELECT terminals.*, locations.name as loc_name, locations.timezone
		FROM terminals LEFT JOIN locations USING (location_id)
		WHERE android_id = ?
	", {}, $s->stash("android_id"));

	$s->stash(
		employees => $employees,		
		moreAvail => ($total > ($startAt + 18)) ? 1 : 0,
		terminal  => $terminal,
	);
} => 'admin';

#
#
#
get '/identify/:badge' => [badge => qr/[\da-f]{16}/i] => sub {
	my $s     = shift;
	my $badge = $s->param("badge");
	my $db    = dbConnect();

	my $owner = $db->selectrow_arrayref("
		SELECT CONCAT_WS(' ', first_name, last_name) as name
		FROM employees
		WHERE active = 1 AND badge = ?
	", {}, $badge);

    my $terminal = $db->selectrow_hashref("
        SELECT terminals.*, locations.name as loc_name, locations.timezone
        FROM terminals LEFT JOIN locations USING (location_id)
        WHERE android_id = ?
    ", {}, $s->stash("android_id"));

	$s->stash(
		owner    => $owner->[0] // undef,
		terminal => $terminal,
	);
} => 'identify';

#
#
#
get '/signout' => sub { # /admin/signout
	my $s = shift;
	$s->session(admin => 0);
	return $s->redirect_to("/main");
};

#
#
#
get '/addBadge/:empID' => sub { # /admin/addBadge/:empID
	my $s = shift;
	my $db = dbConnect();
	my ($empID) = $s->param("empID") =~ /(\d+)/;

	my $employee = $db->selectrow_hashref("
		SELECT * FROM employees WHERE employee_id = ? AND active = 1
		", {}, $empID);


	$s->stash(
		e => $employee,
	);
} => 'addBadge';

#
#
#
get '/setBadge/:empID/:badge' => sub { # /admin/setBadge/:empID/:badge
	my $s = shift;
	my $db = dbConnect();
	my ($empID) = $s->param("empID") =~ /(\d+)/;
	my ($badge) = $s->param("badge") =~ /([\da-f]+)/i;

	my $existing = $db->selectrow_hashref("
		SELECT * FROM employees WHERE badge = ? AND active = 1
	", {}, $badge);

	if (defined($existing)) {
		$s->flash(error => "That badge is already assigned<br>to an employee.");
		return $s->redirect_to("/admin/addBadge/$empID");
	}

	$db->do("
		UPDATE employees SET badge = ? WHERE employee_id = ? AND active = 1 AND badge = ''
	", {}, $badge, $empID);

	return $s->redirect_to('/admin');
};


}; # Admin group

#--------------------------------------------------------------------#
# Error handling
#--------------------------------------------------------------------#
get '/error' => sub { } => 'error';


#--------------------------------------------------------------------#
# returns a timestamp with the database time in UTC
#--------------------------------------------------------------------#
get '/curTime.json' => sub {
    my $s    = shift;
	my $db   = dbConnect();
    my $time = $db->selectrow_arrayref("SELECT UNIX_TIMESTAMP()");
    $s->render(json => { timestamp => $time->[0] });
};


#--------------------------------------------------------------------#
# returns the latest android version available
#--------------------------------------------------------------------#
get '/curVersion.json' => sub {
	my $s = shift;
	$s->render(json => { versionCode => getLatestVersion() });
};


#--------------------------------------------------------------------#
# redirects to the latest android application
#--------------------------------------------------------------------#
get '/latest.apk' => sub {
	my $s = shift;
	my $version = getLatestVersion();
	return $s->redirect_to("/apk/TCTerminal-$version.apk");
};


sub getLatestVersion {
	my $version = 0;
	for my $file (glob("$updateDir/TCTerminal-*.apk")) {
		$file =~ /TCTerminal-(\d+)\.apk/;
		$version = $1 if (defined($1) && ($1 > $version));
	}
	return "$version";
}


#--------------------------------------------------------------------#
#
#--------------------------------------------------------------------#
get '/ping' => sub {
	my $s = shift;
	$s->render(json => { pong => "pong" });
};


#--------------------------------------------------------------------#
#
#--------------------------------------------------------------------#
get '/' => sub { return $_[0]->redirect_to('/main'); };
get '/main' => sub {
    my $s = shift;
} => 'main';


#--------------------------------------------------------------------#
# catch all
#--------------------------------------------------------------------#
any '/:tried' => [tried => qr/.*/] => sub {
	my $s = shift;
	$s->app->log->info("[invalid request] tried: '/" . $s->param("tried") . "'");
	$s->flash(error => "No page for: " . $s->param("tried"));
	return $s->redirect_to("/error");
};





###############################################################################




#
# In minutes, time is convert to the employees local time. $includeAll will
# include the last in punch when there was no matching out punch.
#
helper periodPunches => sub {
	my ($s, $empID, $period, $includeAll) = @_;	
	$includeAll //= 0;

	my $db = dbConnect();

	my $dates = $s->datesForPeriod($period);
	my $empTZ = $db->selectrow_arrayref("
		SELECT timezone FROM employees LEFT JOIN locations USING (location_id)
		WHERE employee_id = ?
	", {}, $empID)->[0];

	my $periodPunches = $db->selectall_arrayref("
		SELECT
			punches.punch_id,
			CONVERT_TZ(time, 'UTC', ?) AS tz_time,
			in_out, 
			fake,
			TIMESTAMPDIFF(DAY, DATE(?), DATE(CONVERT_TZ(time, 'UTC', ?))) AS day_of_period,
			tardy_id
		FROM punches
			LEFT JOIN tardies ON (
				punches.employee_id = tardies.employee_id AND
				punches.punch_id    = tardies.punch_id AND
				tardies.deleted = false
			)
		WHERE
			punches.employee_id = ? AND
			time >= CONVERT_TZ(?, ?, 'UTC') AND
			time <= CONVERT_TZ(?, ?, 'UTC') AND
			punches.deleted = false 
		ORDER BY time
	", { Slice => {} },
		$empTZ,
		$dates->{startSQL}, 
		$empTZ,
		$empID,
		$dates->{startSQL}, $empTZ, 
		$dates->{endSQL},   $empTZ,
	);

	# move punches into their period day
	my @punches;
	push(@{$punches[$_->{day_of_period}]}, $_) for (@$periodPunches);

	my %p;
	for my $dayOfPeriod (0..13) {
		next unless (defined($punches[$dayOfPeriod]));
		my @daysPunches = @{ $punches[$dayOfPeriod] };
		while (scalar(@daysPunches)) {
			my ($in, $out) = (shift(@daysPunches), shift(@daysPunches));
			my $week = ($dayOfPeriod <= 6) ? 1 : 2;

			if (defined($in->{tz_time}) && defined($out->{tz_time})) {
				my $punchMinutes = (roundPunch($out->{tz_time}) - roundPunch($in->{tz_time})) / 60;
				push(@{ $p{$dayOfPeriod} }, {
					in      => roundPunch($in->{tz_time}),
					out     => roundPunch($out->{tz_time}),
					inTime  => $s->justTime(roundPunch($in->{tz_time})),
					outTime => $s->justTime(roundPunch($out->{tz_time})),
					inID    => $in->{punch_id},
					outID   => $out->{punch_id},
					week    => $week,
					fake    => $in->{fake} || $out->{fake},
					minutes => $punchMinutes,
					tardy   => $in->{tardy_id},
				});
			}
			elsif ($includeAll && defined($in->{tz_time})) {
				push(@{ $p{$dayOfPeriod} }, {
					in      => roundPunch($in->{tz_time}),
					inTime  => $s->justTime(roundPunch($in->{tz_time})),
					inID    => $in->{punch_id},
					week    => $week,
					fake    => $in->{fake},
					tardy   => $in->{tardy_id},
				});
			}
		}
	}

	return \%p;
};



#
# these dates and time are for whatever local time zone since
# they are full days includes
#
helper datesForPeriod => sub {
	my ($s, $period) = @_;
	my @start   = Add_Delta_Days(2004, 7, 19, $period * 14);
	my @end     = Add_Delta_Days(@start, 13);
	my @endW1   = Add_Delta_Days(@start, 6);
	my @startW2 = Add_Delta_Days(@start, 7);
	return {
		start        => \@start,
		startW1      => \@start,
		end          => \@end,
		endW2        => \@end,
		endW1        => \@endW1,
		startW2      => \@startW2,
		startEpoch   => Date_to_Time(@start, 0, 0, 0),
		startW2Epoch => Date_to_Time(@startW2, 0, 0, 0),
		endEpoch     => Date_to_Time(@end, 23, 59, 59),
		startSQL     => sprintf("%.4i-%.2i-%.2i 00:00:00", @start),
		endSQL       => sprintf("%.4i-%.2i-%.2i 23:59:59", @end),
		endSQLw1     => sprintf("%.4i-%.2i-%.2i 23:59:59", Add_Delta_Days(@start, 6)),
		startSQLw2   => sprintf("%.4i-%.2i-%.2i 00:00:00", Add_Delta_Days(@start, 7)),
	};
};



#
# returns the punch rounded in epoch format
#
sub roundPunch {
	my $punch = shift;

	$punch =~ s/[\:\-\s]//g;
	my @splitTime = $punch =~ /(....)(..)(..)(..)(..)(..)/;

	# add 30 seconds to round to 1 minute
	@splitTime = Add_Delta_DHMS(@splitTime, 0, 0, 0, 30);
	$splitTime[5] = 0;

	return Date_to_Time(@splitTime);
}



#
#
#
helper justTime => sub {
	my ($s, $timestamp) = @_;
	my @t = Gmtime($timestamp);

	my $ampm = "am";
	if ($t[3] >= 12) {
		$ampm = "pm";
		$t[3] -= 12 if ($t[3] > 12);
	}

	my $time = sprintf("%i:%02i %s", $t[3], $t[4], $ampm);

	return $time;
};


#
#
#
helper round => sub {
	my ($s, $num, $places) = @_;
	return sprintf("%0." . $places . "f", $num);
};


#
# returns the current period we are in
#   - periods are 14 days
#   - the first period (for our app) was 8/02/2004 - 8/15/2004 == period 0
#
helper currentPeriod => sub {
	my $daysSince = Delta_Days(2004, 7, 19, Today());
	return POSIX::floor($daysSince / 14);
};


#
#
#
helper prettyDateRange => sub {
	my ($s, $start, $end) = @_;
	my @months = qw/Blank January Febuary March April May June July August September October November December/;
	my @ending = qw/th st nd rd th th th th th th/;

	my $startMonth = $months[ $start->[1] ];
	my $startDay   = $start->[2];
	my $endMonth   = $months[ $end->[1] ];
	my $endDay     = $end->[2];
	my $endYear    = $end->[0];

	$endMonth = "" if ($endMonth eq $startMonth);
	my $out = "$startMonth $startDay - $endMonth $endDay";

	if ((Today())[0] != $endYear) {
		$out .= " ($endYear)";
	}

	return $out;
};
































#--------------------------------------------------------------------#
#
#--------------------------------------------------------------------#
app->secrets(['Company TCTerminal - asdf12345']);
app->sessions->cookie_name("comptcterminal");
app->sessions->default_expiration(32400);
app->config(hypnotoad => {
	listen       => ['http://*:3428'],
	lock_file    => '/tmp/hypnotoad-tcterminal.lock',
	pid_file     => '/tmp/hypnotoad-tcterminal.pid',
	proxy        => 0,
	workers      => 4,
	clients      => 100,
	accepts      => 1000,
});
app->mode('production');
app->start;


