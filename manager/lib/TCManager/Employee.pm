package TCManager::Employee;

use Mojo::Base 'Mojolicious::Controller';
use Date::Calc qw/Time_to_Date Add_Delta_Days Date_to_Time Timezone Today/;
use Mojo::JSON;
use Data::Dumper;
use LWP::Simple;
use JSON;

#
#
#
sub main {
	my $s = shift;
	my $empID = $s->param("empID");

	my $reasons = $s->db->selectall_arrayref("
		SELECT reason_id, description FROM reasons WHERE standard = 1 AND type = 'P'
	", { Slice => {} });

	my $empTZ = $s->employeeDetails($empID)->{timezone};

	my $tardies = $s->db->selectrow_arrayref("
		SELECT COUNT(*) 
		FROM tardies 
			LEFT JOIN punches USING (punch_id)
		WHERE
			tardies.employee_id = ? AND
			tardies.deleted = 0 AND
			DATE(CONVERT_TZ(time, 'UTC', ?)) >= ?
	", {}, $empID, $empTZ, $s->fiscalStart())->[0];

	$s->stash(
		reasons => $reasons,
		tardies => $tardies // 0,
	);
}


#
#
#
sub punch {
	my $s = shift;
	my $empID = $s->param("empID");
	if ($s->employeeAccess($empID)) {
		my $res = decode_json( get($s->conf->{tcterminal_url} . "/punchFromPunchy/$empID") );
	}

	$s->redirect_to("/employee/$empID");
}


#
#
#
sub tardies {
	my $s     = shift;
	my $empID = $s->param("empID");
	my $emp   = $s->employeeDetails($empID);

	my $reasons = $s->db->selectall_arrayref("
		SELECT reason_id, description FROM reasons WHERE standard = 1 AND type = 'P'
	", { Slice => {} });

	my $tardies = $s->db->selectall_arrayref("
		SELECT 
			tardies.*, 
			DATE_FORMAT(CONVERT_TZ(time, 'UTC', ?), '\%M \%D \%l:\%i:\%s \%p') AS punch_time,
			reasons.description as reason_desc
		FROM tardies
		    LEFT JOIN punches USING (punch_id)
		    LEFT JOIN reasons ON (tardies.reason_id = reasons.reason_id)
		WHERE 
		    tardies.employee_id = ? AND
		    DATE(CONVERT_TZ(time, 'UTC', ?)) >= ?    
		ORDER BY time DESC
	", { Slice => {} }, $emp->{timezone}, $empID, $emp->{timezone}, $s->fiscalStart());

	$s->stash(
		reasons => $reasons,
		tardies => $tardies,
		empName => $emp->{first_name} . " " . $emp->{last_name},
	);
}


#
#
#
sub markTardy {
	my $s     = shift;
	my $empID = $s->param("empID");
	my $inID  = $s->param("inID");

	unless ($s->session("admin") == 1) {
		$s->flash(error => 'Only admins can change tardy status.');
		return $s->redirect_to("/error");
	}

	$s->db->do("
		INSERT INTO tardies (employee_id, punch_id, reason_id, deleted) 
		VALUES (?, ?, NULL, 0)
	", {}, $empID, $inID);
	return $s->redirect_to("/employee/$empID");
}


#
#
#
sub removeTardy {
	my $s       = shift;
	my $tardyID = $s->param("tardyID");
	my $empID   = $s->param("empID");
	my $reason  = $s->param("mpReason") || 0;
	my $other   = $s->param("mpOther")  || "(Nothing entered)";

	unless ($s->session("admin") == 1) {
		$s->flash(error => 'Only admins can change tardy status.');
		return $s->redirect_to("/error");
	}

	if ($reason == 0) {
		# Add a new reason.
		$s->db->do("INSERT INTO reasons (description, standard, type) 
			VALUES (?, 0, 'P')", {}, $other);

		# last_insert_id isn't working 
		# $reason = $s->db->last_insert_id('%', 'time', 'reasons', 'reason_id');
		$reason = $s->db->selectrow_arrayref("SELECT reason_id FROM reasons 
			WHERE description = ? ORDER BY reason_id DESC LIMIT 1", {}, $other)->[0];			
	}

	$s->db->do("
		UPDATE tardies SET deleted = 1, reason_id = ? WHERE tardy_id = ? AND employee_id = ?
	", {}, $reason, $tardyID, $empID);
	
	return $s->redirect_to("/employee/$empID");
}


#
#
#
sub modifyHours {
	my $s     = shift;
	my $empID = $s->param("empID");
	my $week  = $s->param("week");
	my %hours = map { $_ => $s->param($_) // 0 } qw/vacation sick holiday adjust/;

	my $current = $s->db->selectrow_hashref("
		SELECT extra_id, week, vacation, sick, holiday, adjust
		FROM extra_time 
		WHERE employee_id = ? and period = ? and week = ?
	", {}, $empID, $s->session("period"), $week);

	$current->{$_} += $hours{$_} * 60 for (qw/vacation sick holiday adjust/);
	my @params = map { $current->{$_} } qw/vacation sick holiday adjust/;

	# In case there wasn't an existing row.
	if (exists($current->{extra_id})) {
		$s->db->do("
			UPDATE extra_time SET vacation = ?, sick = ?, holiday = ?, adjust = ?
			WHERE extra_id = ?
		", {}, @params, $current->{extra_id});
	}
	else {
		$s->db->do("
			INSERT INTO extra_time (employee_id, period, week, vacation, sick, holiday, adjust)
			VALUES (?, ?, ?, ?, ?, ?, ?)
		", {}, $empID, $s->session("period"), $week, @params);
	}

	$s->redirect_to("/employee/$empID");
}


#
#
#
sub addPunch {
	my $s = shift;
	my ($empID)   = $s->param("apEmpID")   =~ /(\d+)/;
	my ($dop)     = $s->param("apDOP")     =~ /(\d+)/;
	my ($inTime)  = $s->param("apInTime")  =~ /(.*)/;
	my ($inAMPM)  = $s->param("apIampm")   =~ /([ap])/i;
	my ($outTime) = $s->param("apOutTime") =~ /(.*)/;
	my ($outAMPM) = $s->param("apOampm")   =~ /([ap])/i;
	my $reason    = $s->param("apReason");
	my $other     = $s->param("apOther");
	
	return $s->redirect_to("/error") unless ($s->employeeAccess($empID));

	my $period  = $s->session("period");
	my $dates   = $s->datesForPeriod($period);
	my $in      = $s->ampmTimeToFull($period, $dop, $inTime,  $inAMPM);
	my $out     = $s->ampmTimeToFull($period, $dop, $outTime, $outAMPM);
	my $empTZ   = $s->employeeDetails($empID)->{timezone};
	my $punchOK = $s->checkNewPunch($empID, $period, $dop, $in, $out);

	if ($punchOK) {

		if ($reason == 0) {
			# Add a new reason.
			$s->db->do("INSERT INTO reasons (description, standard, type) 
				VALUES (?, 0, 'P')", {}, $other);

			# last_insert_id isn't working 
			# $reason = $s->db->last_insert_id('%', 'time', 'reasons', 'reason_id');
			$reason = $s->db->selectrow_arrayref("SELECT reason_id FROM reasons 
				WHERE description = ? ORDER BY reason_id DESC LIMIT 1", {}, $other)->[0];
		}

		my $insert = $s->db->prepare("
			INSERT INTO punches 
				(punch_id, employee_id, terminal_id, time, in_out, fake, deleted, reason_id, modified_by, modified_on)
			VALUES
				('', ?, 999, CONVERT_TZ(?, '$empTZ', 'UTC'), ?, 1, 0, ?, ?, NOW())
		");

		my $account = $s->session("accountID");
		$insert->execute($empID, $in,  1, $reason, $account);
		$insert->execute($empID, $out, 0, $reason, $account);
	}

	$s->redirect_to("/employee/$empID");
}



#
#
#
sub modifyPunch {
	my $s = shift;

	my $empID      = $s->param("mpEmpID");
	my $inID       = $s->param("mpInPunchID");
	my $outID      = $s->param("mpOutPunchID");
	my $newInTime  = $s->param("mpInTime");
	my $newInAMPM  = $s->param("mpIampm");
	my $newOutTime = $s->param("mpOutTime");
	my $newOutAMPM = $s->param("mpOampm");
	my $reason     = $s->param("mpReason");
	my $other      = $s->param("mpOther");

	# TODO: have a json check for the punch before the modal dissapears
	return $s->redirect_to("/error") unless ($s->employeeAccess($empID));

	my $empTZ = $s->employeeDetails($empID)->{timezone};
	my $date  = $s->db->selectrow_arrayref("
		SELECT DATE(CONVERT_TZ(time, 'UTC', ?)) FROM punches WHERE punch_id=?
	", {}, $empTZ, $inID)->[0];

	my ($period, $dop) = $s->periodFromDate($date);

	my $inDT    = $s->ampmTimeToFull($period, $dop, $newInTime,  $newInAMPM);
	my $outDT   = $s->ampmTimeToFull($period, $dop, $newOutTime, $newOutAMPM);
	my $ok      = $s->checkNewPunch($empID, $period, $dop, $inDT, $outDT, $inID);
	my $account = $s->session("accountID");
	

	if ($ok) {
		if ($reason == 0) {
			# Add a new reason.
			$s->db->do("INSERT INTO reasons (description, standard, type) 
				VALUES (?, 0, 'P')", {}, $other);

			# last_insert_id isn't working 
			# $reason = $s->db->last_insert_id('%', 'time', 'reasons', 'reason_id');
			$reason = $s->db->selectrow_arrayref("SELECT reason_id FROM reasons 
				WHERE description = ? ORDER BY reason_id DESC LIMIT 1", {}, $other)->[0];			
		}

		my $update = $s->db->prepare("
			UPDATE punches SET deleted = 1, modified_by = ?, modified_on = NOW(), reason_id = ?
			WHERE punch_id = ?
		");
		$update->execute($account, $reason, $inID);
		$update->execute($account, $reason, $outID);

		my $insert = $s->db->prepare("
			INSERT INTO punches 
				(employee_id, terminal_id, time, in_out, fake, deleted, reason_id, modified_by, modified_on)
			VALUES (?, 997, CONVERT_TZ(?, ?, 'UTC'), ?, 1, 0, ?, ?, NOW())
		");
		$insert->execute($empID, $inDT,  $empTZ, 1, $reason, $account);
		$insert->execute($empID, $outDT, $empTZ, 0, $reason, $account);
	}

	$s->redirect_to("/employee/$empID");
}



#
#
#
sub deletePunch {
	my ($s) = @_;

	my $empID = $s->param("empID");
	my $inID  = $s->param("inID");
	my $outID = $s->param("outID");

	return $s->redirect_to("/error") unless ($s->employeeAccess($empID));

	$s->db->do("
		UPDATE punches SET deleted = 1 
		WHERE employee_id = ? and (punch_id = ? or punch_id = ?)
	", {}, $empID, $inID, $outID);

	# Try to delete the tardy if it's there.
	$s->db->do("
		UPDATE tardies SET deleted = TRUE 
		WHERE employee_id = ? and punch_id = ?
	", {}, $empID, $inID);

	$s->redirect_to("/employee/$empID");
}



#
# Converts "3:12 pm" to a full date time, no timezone conversion is done
#   eg. 2014-01-22 13:21:00
#
sub ampmTimeToFull {
	my ($s, $period, $dop, $time, $ampm) = @_;

	# Allow just the hours to be entered.
	$time .= ":00" if ($time =~ /^\d+$/);
	my ($hour, $min) = $time =~ /^(\d+)[:\.\s](\d+)/;
	$hour += 12 if ($hour < 12 && $ampm =~ /p/i);
	$hour -= 12 if ($hour == 12 && $ampm =~ /a/i);

	my $dates = $s->datesForPeriod($period);
	my ($y, $m, $d) = Add_Delta_Days(@{$dates->{start}}, $dop);

	return sprintf("%i-%0.2i-%0.2i %0.2i:%0.2i:00", $y, $m, $d, $hour, $min);
}


#
# Returns 1 if punch won't overlap with existing punches, undef otherwise
#   $inTime and $outTime should be full datetimes
#
sub checkNewPunch {
	my ($s, $empID, $period, $dop, $inTime, $outTime, $ignoreID) = @_;

	my $dates = $s->datesForPeriod($period);
	my $inTS  = $s->toTS($inTime);
	my $outTS = $s->toTS($outTime);

	$s->log->debug("Checking new punch -- in: $inTime, out: $outTime");	

	# Make sure the new punch won't overlap with existing ones.
	my $bad = 0;

	if ($outTS <= $inTS) {
		$s->log->debug(">>> Testing punch: out punch is before in punch");
		$bad = 1;
	}

	my $punches = $s->periodPunches($empID, $period);
	for my $p (@{$punches->{$dop}}) {
		$s->log->debug(sprintf(">>> Testing punch -- in: %s, out: %s", 
			$s->toDT($p->{in}), $s->toDT($p->{out}) ));

		if (defined($ignoreID) && $ignoreID == $p->{inID}) {
			$s->log->debug(">>> Testing punch -- skipping, found ignore id");
			next;
		}

		if ($inTS >= $p->{in} && $inTS <= $p->{out}) {
			$bad = 1;
			$s->log->debug(">>> Testing punch -- bad, new in overlaps");
		}
		if ($outTS >= $p->{in} && $outTS <= $p->{out}) {
			$bad = 1;
			$s->log->debug(">>> Testing punch -- bad, new out overlaps");
		}
	}

	$s->log->debug(">>> New punch is: " . ($bad ? "BAD" : "GOOD"));
	return ($bad == 1) ? undef : 1;
}




#
#
#
sub dayTimes {
	my $s = shift;

	my $dop    = $s->param("dayOfPeriod");
	my $empID  = $s->param("empID");
	my $period = $s->session("period");

	my $punches = $s->periodPunches($empID, $period);

	$s->render(json => { punches => \@{$punches->{$dop}} });
}


#
#
#
sub dayTimesByPunch {
	my $s = shift;

	my $empID   = $s->param("empID");
	my $punchID = $s->param("punchID");
	my $period  = $s->session("period");

	my $empTZ = $s->db->selectrow_arrayref("
        SELECT timezone FROM employees LEFT JOIN locations USING (location_id)
        WHERE employee_id = ?
    ", {}, $empID)->[0];

	my $date = $s->db->selectrow_arrayref("
		SELECT DATE(CONVERT_TZ(time, 'UTC', ?)) FROM punches WHERE punch_id=?
	", {}, $empTZ, $punchID)->[0];
	my (undef, $dop) = $s->periodFromDate($date);
	my $punches = $s->periodPunches($empID, $period);

	$s->render(json => { punches => \@{$punches->{$dop}} });
}


#
#
#
sub punchDetails {
	my $s = shift;

	my $empID   = $s->param("empID");
	my $punchID = $s->param("punchID");

	my $empTZ = $s->employeeDetails($empID)->{timezone};
	my $date  = $s->db->selectrow_arrayref("
		SELECT DATE(CONVERT_TZ(time, 'UTC', ?)) FROM punches WHERE punch_id=?
	", {}, $empTZ, $punchID)->[0];

	my ($period, undef) = $s->periodFromDate($date);
	$s->session(period => $period);
	
	return $s->redirect_to("/employee/$empID");
}


1;
