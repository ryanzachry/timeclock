package TCManager::Chart;

use Mojo::Base 'Mojolicious::Controller';
use Date::Calc qw/Time_to_Date Date_to_Time Add_Delta_Days/;
use Mojo::JSON;


#
#
#
sub cTotalsHistory {
	my $s = shift;

	my ($empID) = $s->param("empID") =~ /(\d+)/;
	my $oldestPeriod = $s->currentPeriod() - 27;
	my %totals;
	for my $period ($oldestPeriod..$s->currentPeriod()) {
		my $dates = $s->datesForPeriod($period);
		my $time  = $s->calcEmployeeTime($empID, $period);

		for (qw/regular over vacation sick holiday/) {
			my $w1Time = sprintf("%.2f", $time->{$_ . "W1"} / 60) + 0;
			my $w2Time = sprintf("%.2f", $time->{$_ . "W2"} / 60) + 0;
			my $w1Date = $dates->{startEpoch} * 1000;
			my $w2Date = Date_to_Time(@{$dates->{startW2}}, 0, 0, 0) * 1000;

			push(@{$totals{$_}}, [$w1Date, ($w1Time > 0) ? $w1Time : 0]);
			push(@{$totals{$_}}, [$w2Date, ($w2Time > 0) ? $w2Time : 0]);
		}
	}

	# Offset a bit so the highligh matches up with the bar widths better.
	my $dates = $s->datesForPeriod($s->session("period"));
	$totals{periodStart} = Date_to_Time( Add_Delta_Days(@{$dates->{start}}, -3), 0, 0, 0 ) * 1000;
	$totals{periodEnd}   = Date_to_Time( Add_Delta_Days(@{$dates->{start}}, 10), 0, 0, 0 ) * 1000;

	$s->render(json => \%totals);
}


#
# Charts the hours breakdown for all employees.
#
sub cEmployeeList {
	my $s = shift;

	my $period = $s->session("period");
	my $dates = $s->datesForPeriod($period);

	my %totals;
	for my $empID ($s->accountEmployees()) {
		my $emp  = $s->employeeDetails($empID);
		my $time = $s->calcEmployeeTime($empID, $period);

		$totals{$empID}{name} = $emp->{first_name} . " " . $emp->{last_name};
		$totals{$empID}{empID} = $empID;
		for (qw/regular over vacation sick holiday/) {
			$totals{$empID}{$_} = sprintf("%.2f", $time->{$_} / 60) + 0;
		}
	}

	my %chart;
	for my $e (sort { $a->{name} cmp $b->{name} } values %totals) {
		push(@{ $chart{names} }, $e->{name});
		for (qw/regular over vacation sick holiday/) {
			push(@{$chart{$_}}, {
				name  => $e->{name},
				empID => $e->{empID},
				y     => $e->{$_},
			});
		}
	}

	$s->render(json => \%chart);
}


#
#
#
sub cPeriodSummary {
	my $s = shift;

	my ($empID) = $s->param("empID") =~ /(\d+)/;
	my $time = $s->calcEmployeeTime($empID, $s->session("period"));

	my %series = (
		type => 'pie',
		name => 'Summary'
	);

	my @colors = qw/428BCA D9534F 5CB85C F0AD4E 5BC0DE/;
	for (qw/regular over vacation sick holiday/) {
		my $color = shift(@colors);
		if ($time->{$_} != 0) {
			push(@{$series{data}}, {
				name  => ucfirst($_),
				color => "#$color",
				y     => sprintf("%.2f", $time->{$_} / 60) + 0,
			});
		}
	}

	$s->render(json => \%series);
}


#
#
#
sub cPeriodPunches {
	my $s = shift;

	my ($empID) = $s->param("empID") =~ /(\d+)/;
	my $dates   = $s->datesForPeriod($s->session("period"));
	my $punches = $s->periodPunches($empID, $s->session("period"));
	my $reasons = $s->db->selectall_hashref("
		SELECT
			punch_id,
		    description AS reason,
		    user AS modified_by
		FROM punches 
		    LEFT JOIN reasons USING (reason_id)
		    LEFT JOIN accounts ON (modified_by = account_id)
		WHERE
		    modified_on IS NOT NULL AND
		    time >= ? AND
		    time <= ? AND
		    employee_id = ?
	", "punch_id", {}, 
		$dates->{startSQL},
		$dates->{endSQL},
		$empID
	);

	# [dow, in time, out time]
	# [1, 1375686000*1000, 1375705800*1000], 

	my $startTime = $dates->{startEpoch};
	my %chart;
	for my $dayOfPeriod (0..13) {
		my $week = ($dayOfPeriod < 7) ? "week1" : "week2";
		my $dayOfWeek = $dayOfPeriod % 7;

		# To make sure all days show up in the chart.
		push(@{$chart{$week}}, { data => [[0]] }) unless (exists($punches->{$dayOfPeriod}));

		for my $punch (@{ $punches->{$dayOfPeriod} }) {
			my ($h, $m, $s) = (Time_to_Date($punch->{in}))[3..5];
			my $inTime = $startTime + ($h * 3600) + ($m * 60);

			($h, $m, $s) = (Time_to_Date($punch->{out}))[3..5];
			my $outTime = $startTime + ($h * 3600) + ($m * 60);

			my $reason = "";
			my $color  = '#428BCA';
			if ($punch->{fake} == 1) {
				# Show why it was modified in the tooltip hover.
				$color = '#F0AD4E';
				$reason = $reasons->{ $punch->{inID} }->{reason};
			}

			if ($punch->{tardy}) {
				$color = '#F0AD4E';
			}

			# Make the modified punches stand out yellow orange.
			push(@{$chart{$week}}, {
				color  => $color,
				name   => 'punch',
				reason => $reason,
				tardy  => $punch->{tardy},
				inID   => $punch->{inID},
				data   => [[$dayOfWeek, $inTime * 1000, $outTime * 1000]]
			});
		}
	}

	$s->render(json => {
		data    => \%chart,
		minDate => $dates->{startEpoch},
	});

}


1;