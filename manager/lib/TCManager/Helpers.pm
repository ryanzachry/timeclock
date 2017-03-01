package TCManager::Helpers;

use Mojo::Base 'Mojolicious::Plugin';
use POSIX;
use Date::Calc qw/Today Delta_Days Add_Delta_Days Date_to_Time Time_to_Date Gmtime Add_Delta_DHMS N_Delta_YMD/;
use Data::Dumper;


#
#
#
sub register {
	my ($s, $app) = @_;

	$app->helper(employeeDetails  => \&employeeDetails);
	$app->helper(prettyDateRange  => \&prettyDateRange);
	$app->helper(calcEmployeeTime => \&calcEmployeeTime);
	$app->helper(currentPeriod    => \&currentPeriod);
	$app->helper(datesForPeriod   => \&datesForPeriod);
	$app->helper(extraTime        => \&extraTime);
	$app->helper(actualTime       => \&actualTime);
	$app->helper(prettyTime       => \&prettyTime);
	$app->helper(accountEmployees => \&accountEmployees);
	$app->helper(dumpVar          => \&dumpVar);
	$app->helper(periodPunches    => \&periodPunches);
	$app->helper(employeeAccess   => \&employeeAccess);
	$app->helper(justTime         => \&justTime);
	$app->helper(round            => \&round);
	$app->helper(periodFromDate   => \&periodFromDate);
	$app->helper(fiscalStart      => \&fiscalStart);
	$app->helper(toDT             => \&toDT);
	$app->helper(toTS             => \&toTS);
	$app->helper(periodHolidays   => \&periodHolidays);
	$app->helper(flexModifiers    => \&flexModifiers);
	$app->helper(calcVacationTime => \&calcVacationTime);
}


#
# converts a timestamp to a fully punctuated datetime
#
sub toDT {
	my ($s, $ts) = @_;
	return sprintf("%i-%0.2i-%0.2i %0.2i:%0.2i:%0.2i", Time_to_Date($ts));
}


#
# converts a datetime in either string or array format to a timestamp
#
sub toTS { 
	my ($s, @dt) = @_;

	unless (defined($dt[5])) {
		(@dt) = $dt[0] =~ /(\d+)-(\d+)-(\d+) (\d+):(\d+):(\d+)/;
	}

	return Date_to_Time(@dt);
}


#
#
#
sub fiscalStart {
	my $s = shift;
	my ($y, $m, $d) = Today();
	$y-- if ($m < $s->conf->{fiscal_start_month});
	return sprintf("$y-%02i-01", $s->conf->{fiscal_start_month});
}


#
# Finds the period number and day of period for a given date: yyyy-mm-dd.
#
sub periodFromDate {
	my ($s, $date) = @_;

	my ($y, $m, $d) = $date =~ /(\d+)\-(\d+)\-(\d+)/;
	my $target = Date_to_Time($y, $m, $d, 0, 0, 0);

	for my $period (reverse(1..$s->currentPeriod())) {
		my $dates = $s->datesForPeriod($period);
		if ($target >= $dates->{startEpoch} && $target <= $dates->{endEpoch}) {
			my $dop = Delta_Days(@{$dates->{start}}, $y, $m, $d);
			return $period, $dop;
		}
	}
	
	return undef, undef;
}



#
#
#
sub round {
	my ($s, $num, $places) = @_;
	return sprintf("%0." . $places . "f", $num);
}



#
#
#
sub dumpVar {
	my ($s, $data) = @_;
	$Data::Dumper::Sortkeys = 1;
	return Dumper($data);
}



#
#
#
sub justTime {
	my ($s, $timestamp) = @_;
	my @t = Gmtime($timestamp);

	my $ampm = "am";
	if ($t[3] == 0 && $t[4] == 0) {
		$t[3] = 12;
	}
	elsif ($t[3] >= 12) {
		$ampm = "pm";
		$t[3] -= 12 if ($t[3] > 12);
	}

	my $time = sprintf("%i:%02i %s", $t[3], $t[4], $ampm);

	return $time;
}



#
# Returns an array of the active employees that the logged in 
# account has access to.
#
sub accountEmployees {
	my ($s) = @_;

	my $sql;
	if ($s->session("admin") == 1) {
		# admins get access to everyone
		return split(/,/, $s->db->selectrow_arrayref("
			SELECT GROUP_CONCAT(employee_id SEPARATOR ',') 
			FROM employees 
			WHERE active = TRUE
		")->[0]);
	}
	else {
		# Supervisors only get access to employees assigned to them.
		return split(/[,\|]/, $s->session("access"));
	}

	return undef;
}


#
#
#
sub prettyTime {
	my ($s, $time) = @_;
	my $out = $s->round($time, 2);
	return $time == 0 ? "-" : $out;
}



#
#
#
sub prettyDateRange {
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
}



#
# In minutes, time is convert to the employees local time. $includeAll will
# include the last in punch when there was no matching out punch.
#
sub periodPunches {
	my ($s, $empID, $period, $includeAll) = @_;
	return unless ($s->employeeAccess($empID));

	$includeAll //= 0;

	my $dates = $s->datesForPeriod($period);
	my $empTZ = $s->db->selectrow_arrayref("
		SELECT timezone FROM employees LEFT JOIN locations USING (location_id)
		WHERE employee_id = ?
	", {}, $empID)->[0];

	my $periodPunches = $s->db->selectall_arrayref("
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

	# Move punches into their period day.
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
}




#
#
#
sub employeeDetails {
	my ($s, $empID) = @_;
	return unless $s->employeeAccess($empID);

	return $s->db->selectrow_hashref("
		SELECT 
			employee_id, as400_id, first_name, last_name, ad_name, badge,
			location_id, active, flex, flex_week, shift, temp, status, hire_date,

			TIME_FORMAT(start_mon, '%l:%i') as start_mon, 
			TIME_FORMAT(start_mon, '%p') as start_mon_ampm,

			TIME_FORMAT(start_tue, '%l:%i') as start_tue, 
			TIME_FORMAT(start_tue, '%p') as start_tue_ampm,

			TIME_FORMAT(start_wed, '%l:%i') as start_wed, 
			TIME_FORMAT(start_wed, '%p') as start_wed_ampm,

			TIME_FORMAT(start_thu, '%l:%i') as start_thu, 
			TIME_FORMAT(start_thu, '%p') as start_thu_ampm,

			TIME_FORMAT(start_fri, '%l:%i') as start_fri, 
			TIME_FORMAT(start_fri, '%p') as start_fri_ampm,

			TIME_FORMAT(start_sat, '%l:%i') as start_sat, 
			TIME_FORMAT(start_sat, '%p') as start_sat_ampm,

			TIME_FORMAT(start_sun, '%l:%i') as start_sun, 
			TIME_FORMAT(start_sun, '%p') as start_sun_ampm,

			CONCAT_WS(' ', locations.name, locations.area) AS location, 
			locations.timezone
		FROM employees 
			LEFT JOIN locations USING (location_id)
		WHERE employee_id = ?
	", {}, $empID);
}



#
# Returns 1 or undef if logged in account has access to given employee.
#
sub employeeAccess {
	my ($s, $empID) = @_;
	my @access = $s->accountEmployees();
	for (@access) {
		return 1 if ($empID == $_);
	}
	return undef;
}




#
# Returns just the punch totals for each week of the period in minutes 
# in the employees local time.
#
sub actualTime {
	my ($s, $empID, $period) = @_;
	return unless ($s->employeeAccess($empID));

	my $dates = $s->datesForPeriod($period);
	my $empTZ = $s->db->selectrow_arrayref("
		SELECT timezone FROM employees LEFT JOIN locations USING (location_id)
		WHERE employee_id = ?
	", {}, $empID)->[0];

	my $periodPunches = $s->db->selectall_arrayref("
		SELECT
			--
			-- converted to local time of the employee
			--
			CONVERT_TZ(time, 'UTC', ?) AS tz_time, 
			in_out, 
			TIMESTAMPDIFF(DAY, DATE(?), DATE(CONVERT_TZ(time, 'UTC', ?))) AS day_of_period
		FROM punches
		WHERE			
			employee_id = ? and
			time >= CONVERT_TZ(?, ?, 'UTC') and
			time <= CONVERT_TZ(?, ?, 'UTC') and
			deleted = false
		ORDER BY time
	", { Slice => {} }, 
		$empTZ,
		$dates->{startSQL},
		$empTZ,
		$empID,
		$dates->{startSQL}, $empTZ, 
		$dates->{endSQL}, $empTZ,
	);

	# Move punches into their period day.
	my @punches;
	push(@{$punches[$_->{day_of_period}]}, $_->{tz_time}) for (@$periodPunches);

	my @week = (0, 0, 0);
	for my $dayOfPeriod (0..13) {
		next unless (defined($punches[$dayOfPeriod]));
		my @daysPunches = @{ $punches[$dayOfPeriod] };
		my $weekOfPeriod = ($dayOfPeriod <= 6) ? 1 : 2;
		while (scalar(@daysPunches)) {
			my ($in, $out) = (shift(@daysPunches), shift(@daysPunches));
			next unless (defined($in) && defined($out));

			my $punchMinutes = (roundPunch($out) - roundPunch($in)) / 60;
			$week[ $weekOfPeriod ] += $punchMinutes;
		}
	}

	return $week[1], $week[2];
}


#
# Returns the changes to be made to each week for flex employees.
#
sub flexModifiers { 
	my ($s, $empID, $period) = @_;
	return unless ($s->employeeAccess($empID));

	my $dates    = $s->datesForPeriod($period);
	my $emp      = $s->employeeDetails($empID);
	my @holidays = $s->periodHolidays($period);
	my $punches  = $s->periodPunches($empID, $period);

	# To keep the history correct don't modify period before the switch to the new schedule.
	return (0, 0) if ($period <= 252);
	return (0, 0) if ($emp->{flex} == 0);

	# 'A' week gets the first friday of the period off.
	my $offFriday    = ($emp->{flex_week} =~ /A/i) ?  4 : 11;
	my $workedFriday = ($emp->{flex_week} =~ /A/i) ? 11 :  4;
	--$offFriday while (defined($holidays[$offFriday]) && $holidays[$offFriday] == 1);

	if ($offFriday < 0 || $offFriday == 5 || $offFriday == 6) {
		$s->flash(error => "This shouldn't ever happen, let Ryan know that holidays fell through!");
		return $s->redirect_to("/error");
	}

	my $workedFridayTime = 0;
	if (exists($punches->{$workedFriday})) {
		$workedFridayTime += $_->{minutes} for (@{ $punches->{ $workedFriday }});
	}

	my $offFridayTime = 0;
	if (exists($punches->{$offFriday})) {
		$offFridayTime += $_->{minutes} for (@{ $punches->{ $offFriday }});
	}

	my $workedWeek = 0;
	my $offWeek    = 0;
	if ($workedFridayTime > 0 && $offFridayTime > 0) {
		# Don't move any hours, they get the OT.
	}
	elsif ($holidays[$workedFriday] == 1) {
		$workedWeek -= (4 * 60);
		$offWeek    += (4 * 60);
	}
	elsif ($workedFridayTime > (4 * 60)) {
		my $movedHours = $workedFridayTime - (4 * 60);
		$workedWeek -= $movedHours;
		$offWeek    += $movedHours;
	}
	else {
		# Not a holiday, didn't work > 4 hours on their worked week.
	}

	# Return in the format of week1, week2 changes.
	if ($emp->{flex_week} =~ /A/i) {
		return $offWeek, $workedWeek;
	}
	else {
		return $workedWeek, $offWeek;
	}
}


#
# Returns an array of the the period days that are holidays.
# eg: @holidays = [0, 0, 0, 1, 0, 0, 0, ...]
#
sub periodHolidays {
	my ($s, $period) = @_;

	my $dates = $s->datesForPeriod($period);
	my $holidays = $s->db->selectall_arrayref("
		SELECT 
			`day`, 
			TIMESTAMPDIFF(DAY, DATE(?), `day`) AS day_of_period
		FROM holidays
		WHERE
			`day` >= DATE(?) AND
			`day` <= DATE(?)
		ORDER BY `day`
	", { Slice => {} }, $dates->{startSQL}, $dates->{startSQL}, $dates->{endSQL});

	my @days = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
	$days[ $_->{day_of_period} ] = 1 for (@$holidays);

	return @days;
}



#
# Returns 2 hashrefs of the extra time split by week in minutes.
#
sub extraTime {
	my ($s, $empID, $period) = @_;
	return unless ($s->employeeAccess($empID));

	my $extraTime = $s->db->selectall_hashref("
		SELECT
			vacation, sick, holiday, adjust, week
		FROM 
			extra_time
		WHERE
			employee_id = ". $s->db->quote($empID)  ." and
			period      = ". $s->db->quote($period) ."
	", "week");

	my %week1 = map { $_ => $extraTime->{1}->{$_} // 0 } qw/sick vacation holiday adjust/;
	my %week2 = map { $_ => $extraTime->{2}->{$_} // 0 } qw/sick vacation holiday adjust/;

	my @holidays = $s->periodHolidays($period);
	for my $day (0..13) {
		next unless ($holidays[$day] == 1);
		if ($day <= 6) {
			$week1{holiday} += (8 * 60);
		}
		else {
			$week2{holiday} += (8 * 60);
		}
	}

	return \%week1, \%week2;
}



#
# Returns the remaining time an employee has available for vacation, in minutes.
#
sub calcVacationTime {
	my ($s, $empID) = @_;

	my $emp = $s->db->selectrow_hashref("
		SELECT * FROM employees WHERE employee_id = ?
	", {}, $empID);

	my $vac = 0;
	if (defined($emp->{hire_date}) && $emp->{hire_date} ne "" && $emp->{hire_date} ne "0000-00-00") {
		my ($years) = N_Delta_YMD(split(/\-/, $emp->{hire_date}), Today());
		$vac += 80 * 60;                   # 0 - 6 years get 80 hours 
		$vac += 40 * 60 if ($years >= 7);  # 7 - 14 years get 120 hours
		$vac += 40 * 60 if ($years >= 15); # 15+ years get 160 hours
	}

	return $vac;
}



#
# Returns all the totaled times with breakdowns in minutes.
#
sub calcEmployeeTime {
	my ($s, $empID, $period) = @_;
	return unless ($s->employeeAccess($empID));

	my ($actual1, $actual2)   = $s->actualTime($empID, $period);
	my ($extra1,  $extra2)    = $s->extraTime($empID, $period);
	my ($modWeek1, $modWeek2) = $s->flexModifiers($empID, $period);

	# Add in extra time before overtime calculations, sick doesn't get use for OT.
	my ($week1, $week2) = ($actual1, $actual2);
	for (qw/vacation holiday adjust/) {
		$week1 += $extra1->{$_};
		$week2 += $extra2->{$_};
	}

	$week1 += $modWeek1;
	$week2 += $modWeek2;

	my $over1 = 0;
	if ($week1 > 2400) {
		$over1 = $week1 - 2400;
		$week1 = 2400;
	}
	my $over2 = 0;
	if ($week2 > 2400) {
		$over2 = $week2 - 2400;
		$week2 = 2400;
	}

	my %time = (
		actualW1  => $actual1,
		actualW2  => $actual2,
		regularW1 => $week1 - $extra1->{vacation} - $extra1->{holiday},
		regularW2 => $week2 - $extra2->{vacation} - $extra2->{holiday},
		overW1    => $over1,
		overW2    => $over2,
	);

	# Fill in everything for displaying.
	for my $type (qw/vacation holiday adjust sick/) {
		$time{$type . "W1"} = $extra1->{$type};
		$time{$type . "W2"} = $extra2->{$type};
		$time{$type} = $extra1->{$type} + $extra2->{$type};
	}

	$time{totalW1} = $time{regularW1} + $time{overW1} + $time{sickW1} + $time{vacationW1} + $time{holidayW1};
	$time{totalW2} = $time{regularW2} + $time{overW2} + $time{sickW2} + $time{vacationW2} + $time{holidayW2};
	$time{total}   = $time{totalW1}   + $time{totalW2};

	$time{actual}  = $time{actualW1}  + $time{actualW2};
	$time{regular} = $time{regularW1} + $time{regularW2};
	$time{over}    = $time{overW1}    + $time{overW2};

	return \%time;
}



#
# Returns the current period we are in.
#   - Periods are 14 days
#   - The first period (for our app) was 8/02/2004 - 8/15/2004 == period 0
#
sub currentPeriod {
	my $daysSince = Delta_Days(2004, 7, 19, Today());
	return POSIX::floor($daysSince / 14);
}



#
# These dates and time are for whatever local time zone since
# they are full days includes.
#
sub datesForPeriod {
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
}




#
# Returns the punch rounded to the minute in epoch format.
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



1;
