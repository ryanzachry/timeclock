package TCManager::Main;

use Date::Calc qw/Date_to_Time/;
use Mojo::Base 'Mojolicious::Controller';
use POSIX qw/ceil/;
use Data::Dumper;
use LWP::Simple;
use JSON;


#
#
#
sub slash {
	my $s = shift;
	$s->redirect_to('/main');
}


#
#
#
sub main {
    my $s = shift;
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

	$s->redirect_to("/main");
}


#
# This report is used for plant managers in case of a fire to know who's at work.
#
sub printFireDrill {
	my $s = shift;
	my ($locList) = $s->param("locations") =~ /([\d,]+)/;

	my $empList = $s->db->selectall_arrayref("
		SELECT first_name, last_name 
		FROM employees 
		WHERE active = 1 AND status = 1 AND location_id IN ($locList)
		ORDER BY first_name, last_name
	", { Slice => {} });

	# 04/19/2009 12:30pm
	my @t = localtime(time);
	my $date = sprintf('%0.2i/%0.2i/%0.4i %0.2i:%0.2i', ($t[4] + 1), $t[3], ($t[5] + 1900), $t[2], $t[1]);

	my @out;
	push(@out, ("-" x 80) . "\n");
	push(@out, sprintf("-- Firedrill Report \%57s --\n", $date));
	push(@out, ("-" x 80) . "\n\n");

	my $mid = ceil( scalar(@{$empList}) / 2 );
	for (0..$mid - 1) {
		my $line = sprintf("[ ] \%-35s [ ] \%s\n", 
			$empList->[$_       ]->{first_name} . " " . $empList->[$_       ]->{last_name},
			$empList->[$_ + $mid]->{first_name} . " " . $empList->[$_ + $mid]->{last_name}
		);

		push(@out, $line);
	}

	$s->render(text => join("", @out), format => "txt");
}




#
# Modify the time for more than 1 employee at a time.
#
sub massModify {
	my $s = shift;

	my ($empList) = $s->param("employees") =~ /([\d,]+)/;
	my ($holiday) = $s->param("holiday")   =~ /(-?[\.\d]+)/;
	my ($adjust)  = $s->param("adjust")    =~ /(-?[\.\d]+)/;
	my ($week)    = $s->param("week")      =~ /(\d)/;

	for my $empID (split(/,/, $empList)) {
		next unless $s->employeeAccess($empID);

		my $current = $s->db->selectrow_hashref("
			SELECT extra_id, week, holiday, adjust
			FROM extra_time 
			WHERE employee_id = ? and period = ? and week = ?
		", {}, $empID, $s->session("period"), $week);

		my @params = (
			$current->{holiday} + ($holiday * 60),
			$current->{adjust}  + ($adjust  * 60)
		);

		# in case there wasn't an existing row
		if (exists($current->{extra_id})) {
			$s->db->do("UPDATE extra_time SET holiday = ?, adjust = ? WHERE extra_id = ?", 
				{}, @params, $current->{extra_id});
		}
		else {
			$s->db->do("
				INSERT INTO extra_time (employee_id, period, week, holiday, adjust)
				VALUES (?, ?, ?, ?, ?)
			", {}, $empID, $s->session("period"), $week, @params);
		}
	}

	$s->redirect_to("/main");
}



#
#
#
sub setPeriod {
	my $s = shift;
	my ($period) = $s->param("period") =~ /(\d+)/;
	$s->session(period => $period);
	$s->render(json => { res => "ok" });
}


#
# Change the sessions period from a timestamp within that period.
#
sub setPeriodByTimestamp {
	my $s = shift;
	my ($timestamp) = $s->param("timestamp") =~ /(\d+)/;

	for my $period (reverse(1..$s->currentPeriod())) {
		my $dates = $s->datesForPeriod($period);
		if ($timestamp >= $dates->{startEpoch} && $timestamp <= $dates->{endEpoch}) {
			$s->session(period => $period);
			last;
		}
	}

	$s->render(json => { res => "ok" });
}


#
# Change the sessions period from a date within that period.
#
sub setPeriodByDate {
	my $s = shift;
	my ($y, $m, $d) = $s->param("date") =~ /(\d+)\-(\d+)\-(\d+)/;
	my $target = Date_to_Time($y, $m, $d, 0, 0, 0);

	for my $period (reverse(1..$s->currentPeriod())) {
		my $dates = $s->datesForPeriod($period);
		if ($target >= $dates->{startEpoch} && $target <= $dates->{endEpoch}) {
			$s->session(period => $period);
			last;
		}
	}

	$s->render(json => { res => "ok" });
}


#
#
#
sub error {
	my $s = shift;
}



1;
