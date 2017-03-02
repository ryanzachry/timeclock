package TCManager::Admin;

use Mojo::Base 'Mojolicious::Controller';
use Date::Calc qw/Time_to_Date Date_to_Time Add_Delta_Days Today Delta_Days Date_to_Days N_Delta_YMD/;
use Mojo::JSON;
use Data::Dumper;
use Net::FTP;
use File::Temp qw/tempfile/;
use POSIX qw/floor/;


#--------------------------------------------------------------------#
# Upload
#--------------------------------------------------------------------#

#
# 
#
sub upload {
	my $s     = shift;
	my $dates = $s->datesForPeriod($s->session("period"));

	# The cycle and quarter are based off the following thursday after the
	# period ends. the number and month that the check actually clears to
	# everyones bank accounts.

	# Periods end on Sunday, payDate is the next Thursday.
	my @payDate = Add_Delta_Days(@{$dates->{end}}, 4);

	# Find first Thursday of the month.
	my @firstPaycheck = @payDate;
	do {
		@firstPaycheck = Add_Delta_Days(@firstPaycheck, -14);
	} while ($firstPaycheck[1] == $payDate[1]);
	@firstPaycheck = Add_Delta_Days(@firstPaycheck, 14);

	my $payCycle = 1;
	until ($firstPaycheck[2] == $payDate[2]) {
		$payCycle++;
		@firstPaycheck = Add_Delta_Days(@firstPaycheck, 14);
		last if ($payCycle > 5);
	}

	$s->stash(
		payQuarter => $payDate[1],
		payCycle   => $payCycle,
	);
}


#
# Uploads time to IBM iSeries for payroll.
#
sub sendToAS400 {
	my $s = shift;

	my $compNum    = 1;
	my $dayNum     = 1;
	my $payCycle   = $s->param("payCycle");
	my $payQuarter = $s->param("payQuarter");

	my @out;
	push(@out, sprintf("P1%0.2i%0.1i%0.2i%0.2i", $dayNum, $payCycle, $payQuarter, $compNum));

	my $employees = $s->db->selectall_arrayref("
		SELECT * FROM employees WHERE active = 1 AND temp = 0 
		ORDER BY first_name, last_name
	", { Slice => {} });

	for my $e (@$employees) {
		my $t = $s->calcEmployeeTime($e->{employee_id}, $s->session("period"));
		# iSeries wants hours formatted a bit different.
		for (qw/regular over sick vacation holiday/) {
			$t->{$_} = sprintf("%0.0f", $t->{$_} / 60 * 100);
		}

		# iSeries throws errors if there are 0 hours for a line, skip them.
		if ($t->{regular} > 0 || $t->{over} > 0) {
			push(@out, sprintf("P3%0.5i%s%0.5i  %0.5i", $e->{as400_id}, ' ' x 21, $t->{regular}, $t->{over}));
		}

		push(@out, sprintf("P3%0.5i%sS %0.5i", $e->{as400_id}, ' ' x 26, $t->{sick}    )) if ($t->{sick}     > 0);
		push(@out, sprintf("P3%0.5i%sVA%0.5i", $e->{as400_id}, ' ' x 26, $t->{vacation})) if ($t->{vacation} > 0);
		push(@out, sprintf("P3%0.5i%sHL%0.5i", $e->{as400_id}, ' ' x 26, $t->{holiday} )) if ($t->{holiday}  > 0);
	}

	my ($fh, $localFile) = tempfile(UNLINK => 0);
	print $fh "$_\n" for (@out);
	close($fh);

	my $ftp = Net::FTP->new($s->conf->{iseries_host});
	$ftp->login($s->conf->{iseries_user}, $s->conf->{iseries_pass});
	$ftp->cwd("RSF");
	$ftp->put($localFile, "PYR020F");
	$ftp->quit();

	unlink($localFile);

	$s->flash(sent => "Payroll uploaded");
	$s->redirect_to("/admin/upload");
}



#
#
#
sub download {
	my $s     = shift;
	my $dates = $s->datesForPeriod($s->session("period"));

	# The cycle and quarter are based off the following Thursday after the
	# period ends. The number and month that the check actually clears to
	# everyones bank accounts.

	# Periods end on Sunday, payDate is the next Thursday.
	my @payDate = Add_Delta_Days(@{$dates->{end}}, 4);

	# Find the first Thursday of the month.
	my @firstPaycheck = @payDate;
	do {
		@firstPaycheck = Add_Delta_Days(@firstPaycheck, -14);
	} while ($firstPaycheck[1] == $payDate[1]);
	@firstPaycheck = Add_Delta_Days(@firstPaycheck, 14);

	my $payCycle = 1;
	until ($firstPaycheck[2] == $payDate[2]) {
		$payCycle++;
		@firstPaycheck = Add_Delta_Days(@firstPaycheck, 14);
		last if ($payCycle > 5);
	}

	$s->stash(
		payQuarter => $payDate[1],
		payCycle   => $payCycle,
	);
}



#
# This generates a CSV suitable for uploading to an outside HR payroll platform, Zuman.
#
sub makeHoursCSV {
	my $s = shift;

	my $compNum    = 1;
	my $dayNum     = 1;
	my $payCycle   = $s->param("payCycle");
	my $payQuarter = $s->param("payQuarter");

	my %edtCode = (
		regular  => "RegHrly",
		over     => "OTStraight",
		sick     => "SickTaken",
		holiday  => "HolTaken",
		vacation => "PTOTaken",
	);

	my @out;
	push(@out, "IDENTITY,IDENTITYTYPE,ORGCODE,EDTCODE,SHIFTCODE,WORKSTARTDATE,HOURS,LOCATIONCODE,ACTIVITYCODE,PAYRATE,PAYAMOUNT,WORKERSCOMPCODE,CHECKTAG,BORGCODE,DEDUCTIONCLASS");
	# push(@out, sprintf("P1%0.2i%0.1i%0.2i%0.2i", $dayNum, $payCycle, $payQuarter, $compNum));

	my $employees = $s->db->selectall_arrayref("
		SELECT * FROM employees WHERE active = 1 AND temp = 0 
		ORDER BY first_name, last_name
	", { Slice => {} });

	my @sdTmp = @{ $s->datesForPeriod( $s->session("period") )->{start} };
	my $startDate = sprintf("%.2i/%.2i/%.4i", $sdTmp[1], $sdTmp[2], $sdTmp[0]);

	for my $e (@$employees) {
		my $t = $s->calcEmployeeTime($e->{employee_id}, $s->session("period"));
		my $shiftCode = ($e->{shift} == 1) ? "D" : "N";

		for my $type (qw/regular over sick vacation holiday/) {
			# PTO is done in Zuman, only post punched time.
			if ($type eq "regular" || $type eq "over" || $type eq "holiday") {
				my $hours = sprintf("%0.2f", $t->{$type} / 60);
				if ($hours != 0) {
					push(@out, sprintf("COMP-%s,EmpNo,,%s,%s,%s,%0.2f,,none,0,0,,R,,none", 
						$e->{as400_id},
						$edtCode{$type},
						$shiftCode,
						$startDate,
						$hours, 
					));
				}
			}
		}
	}

	my @endTmp = @{ $s->datesForPeriod( $s->session("period") )->{end} };
	my $endDate = sprintf("%.2i%.2i%.4i", $endTmp[1], $endTmp[2], $endTmp[0]);

	my $filename = "PersonHours-$endDate-COMPBW.csv";
	$s->res->headers->content_type('text/csv');
	$s->res->headers->content_disposition("attachment; filename=$filename;");
	$s->render(format => 'txt', data => join("\n", @out));
}



#--------------------------------------------------------------------#
# Reasons
#--------------------------------------------------------------------#

#
#
#
sub punchReasons { }
sub tardyReasons { }


#
#
#
sub removePunchReason {
	my $s = shift;
	my ($id) = $s->param("id") =~ /(\d+)/;
	$s->db->do("DELETE FROM reasons WHERE reason_id = ?", {}, $id);
	return $s->redirect_to("/admin/punchReasons");
}

sub removeTardyReason {
	my $s = shift;
	my ($id) = $s->param("id") =~ /(\d+)/;
	$s->db->do("DELETE FROM reasons WHERE reason_id = ?", {}, $id);
	return $s->redirect_to("/admin/tardyReasons");
}


#
#
#
sub addPunchReason {
	my $s = shift;
	my $desc = $s->param("desc");
	$s->db->do("INSERT INTO reasons (description, standard, type) VALUES (?, 1, 'P')", {}, $desc);
	return $s->redirect_to("/admin/punchReasons");
}

sub addTardyReason {
	my $s = shift;
	my $desc = $s->param("desc");
	$s->db->do("INSERT INTO reasons (description, standard, type) VALUES (?, 1, 'T')", {}, $desc);
	return $s->redirect_to("/admin/tardyReasons");
}


#--------------------------------------------------------------------#
# Accounts
#--------------------------------------------------------------------#

#
#
#
sub accounts {
	my $s = shift;

	my $admins = $s->db->selectall_arrayref("
		SELECT 
			account_id AS id, user, access, comments, 
			CONCAT_WS(' ', name, area) as loc_desc, timezone
		FROM accounts 
			LEFT JOIN locations USING (location_id)
		WHERE active = 1 AND admin = 1
		ORDER BY user"
	, { Slice => {} });

	my $regulars = $s->db->selectall_arrayref("
		SELECT 
			account_id AS id, user, access, comments, 
			CONCAT_WS(' ', name, area) as loc_desc, timezone
		FROM accounts 
			LEFT JOIN locations USING (location_id)
		WHERE active = 1 AND admin = 0
		ORDER BY user"
	, { Slice => {} });

	my $locations = $s->db->selectall_arrayref("
		SELECT 
			location_id AS id,
			CONCAT_WS(' ', name, area) AS loc_desc,
			timezone
		FROM locations
		ORDER BY loc_desc
	", { Slice => {} });

	$s->stash(
		admins    => $admins,
		regulars  => $regulars,
		locations => $locations,
	);
}


#
#
#
sub editAccount {
	my $s = shift;

	my ($id)     = $s->param("eID")    =~ /(\d+)/;
	my ($admin)  = $s->param("eAdmin") =~ /([01])/;
	my $location = $s->param("eLocation");
	my $comments = $s->param("eComments");

	$s->db->do("
		UPDATE accounts 
		SET admin = ?, location_id = ?, comments = ?
		WHERE account_id = ?
	", {}, $admin, $location, $comments, $id);

	return $s->redirect_to("/admin/accounts");
}


#
#
#
sub editAccountAccess {
	my $s = shift;

	my ($id)     = $s->param("eaID")     =~ /(\d+)/;
	my ($access) = $s->param("eaAccess") =~ /([\d,]+)/;

	$s->db->do("
		UPDATE accounts SET access = ? WHERE account_id = ?
	", {}, $access, $id);

	return $s->redirect_to("/admin/accounts");
}


#
#
#
sub deleteAccount {
	my $s = shift;
	my ($id) = $s->param("id") =~ /(\d+)/;
	$s->db->do("UPDATE accounts SET active = 0 WHERE account_id = ?", {}, $id);
	return $s->redirect_to("/admin/accounts");
}


#
#
#
sub addAccount {
	my $s = shift;

	my $user     = $s->param("user");
	my $admin    = $s->param("admin");
	my $location = $s->param("location");
	my $comments = $s->param("comments");

	if (!$user) {
		$s->flash(error => "No username given!");
		return $s->redirect_to("/admin/accounts");
	}

	my $res = $s->db->selectrow_arrayref("SELECT user FROM accounts WHERE active = 1 AND user = ?", {}, $user);
	if (defined($res->[0])) {
		$s->flash(error => "Username $user is already in use!");
		return $s->redirect_to("/admin/accounts");
	}

	$s->db->do("
		INSERT INTO accounts (user, auth_ad, admin, active, comments, location_id)
		VALUES (?, 1, ?, 1, ?, ?)
	", {}, $user, $admin, $comments, $location);

	return $s->redirect_to("/admin/accounts");
}


#
#
#
sub accountDetails {
	my $s = shift;
	my ($id) = $s->param("id") =~ /(\d+)/;

	my $account = $s->db->selectrow_hashref("
		SELECT 
			accounts.*, location_id, CONCAT_WS(' ', name, area) as loc_desc, timezone
		FROM accounts
			LEFT JOIN locations USING (location_id)
		WHERE active = 1 AND account_id = ?
	", {}, $id);

	$s->render(json => $account);
}


#
#
#
sub accountAccess {
	my $s = shift;
	my ($id) = $s->param("id") =~ /(\d+)/;

	my $user = $s->db->selectrow_arrayref("
		SELECT access, user FROM accounts WHERE account_id = ?
	", {}, $id);

	my $emps = $s->db->selectall_arrayref("
		SELECT employee_id, CONCAT_WS(' ', first_name, last_name) as name
		FROM employees
		WHERE active = TRUE
		ORDER BY name
	", { Slice => {} });

	my @access = split(/,/, $user->[0]);

	$s->render(json => { 
		access => \@access,
		user   => $user->[1],
		emps   => $emps,
	});
}



#--------------------------------------------------------------------#
# Employees
#--------------------------------------------------------------------#


#
#
#
sub employees {
	my $s = shift;

	my $disabled = $s->db->selectall_arrayref("
		SELECT * FROM employees WHERE active = false 
		ORDER BY first_name, last_name
	", { Slice => {} });

	$s->stash(disabled => $disabled);
}


#
#
#
sub restoreEmployee {
	my $s = shift;
	my ($empID) = $s->param("empID") =~ /(\d+)/;

	my $emp = $s->db->selectrow_hashref("
		SELECT * FROM employees WHERE employee_id = ? AND active = false
	", {}, $empID);

	if (!defined($emp)) {
		$s->flash(error => "Unable to find that employee to restore");
		return $s->redirect_to("/error");
	}

	my $existing = $s->db->selectrow_hashref("
		SELECT * FROM employees WHERE as400_id = ? AND active = TRUE
	", {}, $emp->{as400_id});

	if (defined($existing)) {
		$s->flash(error => "Another active employee is already using that AS400 ID");
		return $s->redirect_to("/error");
	}

	$s->db->do("UPDATE employees SET active = true WHERE employee_id = ?", {}, $empID);
	return $s->redirect_to("/admin/employees");
}


#
#
#
sub editEmployee {
	my $s = shift;
	my ($empID) = $s->param("id") =~ /(\d+)/;

	my $locations = $s->db->selectall_arrayref("
		SELECT 
			location_id AS id,
			CONCAT_WS(' ', name, area) AS loc_desc,
			timezone
		FROM locations
		ORDER BY loc_desc
	", { Slice => {} });


	$s->stash(
		locations => $locations,
	);
}


#
#
#
sub deleteEmployee {
	my $s = shift;
	my ($empID) = $s->param("id") =~ /(\d+)/;
	$s->db->do("UPDATE employees SET active = FALSE WHERE employee_id = ?", {}, $empID);
	return $s->redirect_to("/admin/employees");
}


#
#
#
sub saveEmployee {
	my $s = shift;

	my @params = qw/as400_id first_name last_name ad_name badge location_id flex flex_week shift temp hire_date employee_id/;
	my %e = map { $_ => $s->param($_) || '' } @params;

	$e{flex_week} = $e{flex};
	$e{flex} = ($e{flex} eq "A" || $e{flex} eq "B") ? 1 : 0;

	$s->db->do("
		UPDATE employees SET 
			as400_id = ?, first_name = ?, last_name = ?, ad_name = ?, badge = ?,
			location_id = ?, flex = ?, flex_week = ?, shift = ?, temp = ?, hire_date = ?
		WHERE employee_id = ?
	", {}, map { $e{$_} } @params);


	# All the start times.
	my (@times, %t);
	for (qw/Mon Tue Wed Thu Fri Sat Sun/) {
		if ($s->param("st$_"."Enable")) {
			my ($h, $m) = $s->param("st$_") =~ /(\d+)[:\s\.](\d+)/;
			# allow just the hours to be input
			unless (defined($h)) {
				($h) = $s->param("st$_") =~ /(\d+)/;
				$m = 0;
			}
			my $ampm = $s->param("st$_"."AMPM");

			$h = 0   if ($h == 12 && $ampm =~ /A/);
			$h += 12 if ($ampm =~ /P/);
			my $time = sprintf("%0.2i:%0.2i:00", $h, $m);
			
			$s->db->do("UPDATE employees SET start_".lc($_)." = ? WHERE employee_id = ?", {},
				$time, $e{employee_id});
		}
		else {
			$s->db->do("UPDATE employees SET start_".lc($_)." = NULL WHERE employee_id = ?", {},
				$e{employee_id});
		}
	}

	return $s->redirect_to("/admin/employees");
}


#
#
#
sub newEmployee {
	my $s = shift;

	my $locations = $s->db->selectall_arrayref("
		SELECT 
			location_id AS id,
			CONCAT_WS(' ', name, area) AS loc_desc,
			timezone
		FROM locations
		ORDER BY loc_desc
	", { Slice => {} });

	$s->stash(locations => $locations);
}


#
#
#
sub addEmployee {
	my $s = shift;

	my @params = qw/as400_id first_name last_name ad_name badge location_id flex flex_week shift temp/;
	my %e = map { $_ => $s->param($_) || '' } @params;

	# Even though we don't rely on as400_id we can't let it duplicate because it is all the 
	# as400 uses for employees.
	my $dump = $s->db->selectrow_arrayref("SELECT as400_id FROM employees WHERE as400_id = ?", {}, $e{as400_id});
	if (defined($dump->[0])) {
		$s->flash(error => "Another employee is already using that ID!");
		return $s->redirect_to("/error");
	}

	$e{flex_week} = $e{flex};
	$e{flex} = ($e{flex} eq "A" || $e{flex} eq "B") ? 1 : 0;

	$s->db->do("
		INSERT INTO employees 
			(as400_id, first_name, last_name, ad_name, badge, location_id, flex, flex_week, shift, temp, active, status)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, 0)
	", {}, map { $e{$_} } @params);


	# last_insert_id wasn't working...
	my $empID = $s->db->selectrow_arrayref("
		SELECT employee_id FROM employees WHERE as400_id = ? AND active = 1 AND first_name = ? AND last_name = ?
		", {}, $e{as400_id}, $e{first_name}, $e{last_name})->[0];

	# All the start times.
	my (@times, %t);
	for (qw/Mon Tue Wed Thu Fri Sat Sun/) {
		if ($s->param("st$_"."Enable")) {
			my ($h, $m) = $s->param("st$_") =~ /(\d+)[:\s\.](\d+)/;
			# allow just the hours to be input
			unless (defined($h)) {
				($h) = $s->param("st$_") =~ /(\d+)/;
				$m = 0;
			}
			my $ampm = $s->param("st$_"."AMPM");

			$h = 0   if ($h == 12 && $ampm =~ /A/);
			$h += 12 if ($ampm =~ /P/);
			my $time = sprintf("%0.2i:%0.2i:00", $h, $m);
			
			$s->db->do("UPDATE employees SET start_".lc($_)." = ? WHERE employee_id = ?", {}, $time, $empID);
		}
		else {
			$s->db->do("UPDATE employees SET start_".lc($_)." = NULL WHERE employee_id = ?", {}, $empID);
		}
	}


	return $s->redirect_to("/admin/employees");
}



#--------------------------------------------------------------------#
# Holidays
#--------------------------------------------------------------------#

#
#
#
sub holidays {
	my $s = shift;

}


#
#
#
sub removeHoliday {
	my $s  = shift;
	my $id = $s->param("id");
	$s->db->do("DELETE FROM holidays WHERE holiday_id = ?", {}, $id);
	return $s->redirect_to('/admin/holidays');
}


#
#
#
sub addHoliday {
	my $s = shift;

	my (@day) = $s->param("day") =~ /(\d+)[\/\-\s](\d+)[\/\-\s](\d+)/;
	$day[2] += 2000 if ($day[2] < 100);

	my $date = sprintf("%0.4i-%0.2i-%0.2i", $day[2], $day[0], $day[1]);
	$s->db->do("INSERT INTO holidays (day) VALUES (?)", {}, $date);

	return $s->redirect_to('/admin/holidays');
}


1;
