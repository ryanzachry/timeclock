#!/usr/bin/env perl
use strict;
use warnings;
use DBI;
use Mail::Sendmail;

#
# Handles nightly cleanup of punches, must be run every hour on the hour.
#

### TODO: might be better to run this on the db server instead just in case ntp gets off...

my $db = DBI->connect("DBI:mysql:time:db.host", "user", "pass");
my $dbTZ = "US/Central";

# TODO: shit fix. The db server really needs to be in the new day for everything to work out
# so give it a couple seconds in case our clocks is a little off.
sleep(3);

# find the locations that just entering the new day
my $locations = $db->selectrow_hashref("
	SELECT
		timezone,
		GROUP_CONCAT(location_id) AS locations,
		TIME_TO_SEC( 
			TIMEDIFF(
				-- actual time of today
				CONVERT_TZ(NOW(), '$dbTZ', timezone),
				-- start of today
				CONCAT_WS(' ', DATE( CONVERT_TZ(NOW(), '$dbTZ', timezone) ), '00:00:00')
			) 
		) AS remaining_seconds,
		DATE( CONVERT_TZ(NOW(), '$dbTZ', timezone) ) AS day
	FROM locations
	GROUP BY timezone
	HAVING remaining_seconds BETWEEN 0 AND 30
");

exit unless (defined($locations));

# $locations->{day} is the new day, not the one we are cleaning up
my $today     = $locations->{day};
my $yesterday = $db->selectrow_arrayref("SELECT DATE_SUB(?, INTERVAL 1 DAY)", {}, $today)->[0];

# only pull the employees who's timezone is currently at the end of day
my $employees = $db->selectall_hashref("
	SELECT *
	FROM employees 
		LEFT JOIN locations USING (location_id)
	WHERE 
		active = TRUE AND
		location_id IN (". $locations->{locations} .")
", "employee_id");


# punch everyone out that missed their out punch
my %problems;
for my $emp (values %$employees) {
	if ($emp->{status} == 1) {
		$db->do("UPDATE employees SET status = 0 WHERE employee_id = ?", {}, $emp->{employee_id});
		$db->do("
			INSERT INTO punches 
				(employee_id, terminal_id, time, in_out, fake, deleted, reason_id, modified_by, modified_on) 
			VALUES (?, 995, CONVERT_TZ(?, ?, 'UTC'), 0, 1, 0, 3, 0, NOW())
		", {}, $emp->{employee_id}, "$yesterday 23:59:59", $emp->{timezone});
	
		# if they are second shift workers punch them back in
		if ($emp->{shift} == 2) {
			$db->do("UPDATE employees SET status = 1 WHERE employee_id = ?", {}, $emp->{employee_id});
			$db->do("
				INSERT INTO punches
					(employee_id, terminal_id, time, in_out, fake, deleted, reason_id, modified_by, modified_on) 
				VALUES (?, 995, CONVERT_TZ(?, ?, 'UTC'), 1, 1, 0, 3, 0, NOW())
			", {}, $emp->{employee_id}, "$today 00:00:01", $emp->{timezone});
		}
		else {
			$problems{ $emp->{employee_id} }{missedOutPunch} = 1;
		}
	}
	
	# see if there are an odd number of punches
	my $count = $db->selectrow_arrayref("
		SELECT COUNT(*) FROM punches WHERE employee_id = ? and DATE(CONVERT_TZ(time, 'UTC', ?)) = ?
	", {}, $emp->{employee_id}, $emp->{timezone}, $yesterday);

	if ($count % 2) {
		$problems{ $emp->{employee_id} }{oddNumberPunches} = 1;
	}


	# see if they had a tardy marked
	my $tardies = $db->selectall_arrayref("
		SELECT time
		FROM tardies 
			LEFT JOIN punches USING (punch_id)
		WHERE
			tardies.employee_id = ? AND
			tardies.deleted = 0 AND
			DATE(CONVERT_TZ(time, 'UTC', ?)) >= ? AND
			DATE(CONVERT_TZ(time, 'UTC', ?)) <= ?
	", { Slice => {} }, 
		$emp->{employee_id}, 
		$emp->{timezone}, "$yesterday 00:00:00", 
		$emp->{timezone}, "$yesterday 23:59:59"
	);

	if (scalar(@$tardies)) {
		$problems{ $emp->{employee_id} }{tardies} = 1;
	}

}


# email the supervisors about the missed punches
my $supers = $db->selectall_arrayref("SELECT access, email FROM accounts WHERE active = 1", { Slice => {} });
for my $empID (keys %problems) {
	my $empName = $employees->{$empID}->{first_name} . " " . $employees->{$empID}->{last_name};
	my @to;
	for (@$supers) {
		push(@to, $_->{email}) if (grep { /^$empID$/ } split(/,/, $_->{access}));
	}

	# let me know if someone isn't assigned a supervisor
	if (scalar(@to) == 0) {
		email('admin@company.com', "[TIMECLOCK] no super assigned for: $empID",
			"$empName doesn't have a supervisor assigned to them to email.");
	}
	

	# bigger problems if i get this
	if (exists($problems{$empID}{oddNumberPunches})) {
		email('admin@company.com', "[TIMECLOCK] odd punches: $empID", 
			"$empName is showing an odd number of punches for $yesterday");
	}

	if (defined($problems{$empID}{missedOutPunch})) {
		for (@to) {
			email($_, "$empName did not punch out", "$empName had no out punch on $yesterday");
		}
	}

	if (defined($problems{$empID}{tardies})) {
		for (@to) {
			email($_, "$empName was tardy", "$empName was marked tardy on $yesterday");
		}
	}

}




sub email {
	my ($to, $subject, $msg) = @_;

	my %mail = (
		To      => $to,
		From    => 'timeclock@company.com',
		Subject => $subject,
		Smtp    => 'smtp.company.com',
		Message => $msg,
		'X-TCT' => 'punching cron'
	);

	sendmail(%mail);
	print "$_: $mail{$_}\n" for (keys %mail);
	print "\n\n";
}
