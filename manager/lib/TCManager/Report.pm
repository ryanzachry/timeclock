package TCManager::Report;

use Mojo::Base 'Mojolicious::Controller';
use Date::Calc qw/Time_to_Date/;
use Data::Dumper;
use Mojo::JSON;


#
# Times will be in each employees local timezone.
#
sub modifiedPunches {
	my $s = shift;	

	my $dates = $s->datesForPeriod($s->session("period"));
	my $res   = $s->db->selectall_arrayref("
		SELECT
			employee_id,
		    CONCAT_WS(' ', first_name, last_name) AS name,
		    CONVERT_TZ(time, 'UTC', timezone) AS tz_time,
		    description AS reason,
		    user AS modified_by,
		    CONVERT_TZ(modified_on, 'UTC', timezone) AS modified_time
		FROM punches 
		    LEFT JOIN employees USING (employee_id)
		    LEFT JOIN reasons USING (reason_id)
		    LEFT JOIN accounts ON (modified_by = account_id)    		    
		    LEFT JOIN locations ON (employees.location_id = locations.location_id)
		WHERE
		    modified_on IS NOT NULL AND
		    time >= ? AND
		    time <= ?
		ORDER BY first_name, last_name, tz_time
	", { Slice => {} }, 
		$dates->{startSQL},
		$dates->{endSQL}
	);

	my %punches;
	push(@{$punches{ $_->{name} }}, $_) for (@$res);


	$s->stash(
		punches => \%punches
	);
}


#
#
#
sub fireDrill {
	my $s = shift;

	my $access = join(",", $s->accountEmployees());
	my $res = $s->db->selectall_arrayref("
		SELECT 
		    CONCAT_WS(' ', first_name, last_name) AS name,
		    locations.area AS location
		FROM employees
		    LEFT JOIN locations USING (location_id)
		WHERE
		    active = 1 AND
		    status = 1 AND
		    employee_id IN ($access)
		ORDER BY location, name
	", { Slice => {} });

	$s->stash(list => $res);
}


#
#
#
sub totals {
	my $s = shift;


}


#
#
#
sub detailed {
	my $s = shift;

	my %data;
	for my $empID ($s->accountEmployees()) {
		$data{$empID} = {
			emp     => $s->employeeDetails($empID),
			punches => $s->periodPunches($empID, $s->session("period")),
			time    => $s->calcEmployeeTime($empID, $s->session("period")),
		};
	}

	$s->stash(employees => \%data);
}


#
#
#
sub tardies {
	my $s = shift;

	my %list;
	for my $empID ($s->accountEmployees()) {
		my $emp = $s->employeeDetails($empID);		
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
			ORDER BY time ASC
		", { Slice => {} }, $emp->{timezone}, $empID, $emp->{timezone}, $s->fiscalStart());

		next unless (scalar(@$tardies) > 0);

		$list{$empID} = {
			name       => $emp->{first_name} . " " . $emp->{last_name},
			tardies    => $tardies,
			numTardies => scalar( grep { $_->{deleted} == 0 } @$tardies ),
		};
	}

	$s->stash(list => \%list);
}




1;
