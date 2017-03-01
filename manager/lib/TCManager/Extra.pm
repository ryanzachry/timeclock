package TCManager::Extra;

use Date::Calc qw/Date_to_Time/;
use Digest::MD5;
use Mojo::Base 'Mojolicious::Controller';


#
#
#
sub status {
	my $s = shift;
	$s->param(loc => $s->getLocations());
	$s->stash(
		font   => $s->param("font")   // "1.5",
		cols   => $s->param("cols")   // "4",
		weight => $s->param("weight") // "normal",
	);
}


#
#
#
sub employees {
	my $s = shift;
	my $locations = $s->getLocations();

	my $employees = $s->db->selectall_arrayref("
		SELECT 
			employee_id, 
			CONCAT_WS(' ', first_name, last_name) as name,
			status
		FROM employees
		WHERE
			active = TRUE AND
			location_id in ($locations)
		ORDER BY name ASC
	", { Slice => {} });

	my $namesMD5  = Digest::MD5->new();
	my $statusMD5 = Digest::MD5->new();
	for (@$employees) {
		$statusMD5->add($_->{employee_id} . $_->{name} . $_->{status});
		$namesMD5-> add($_->{employee_id} . $_->{name});
	}

	$s->render(json => {
		namesMD5  => $namesMD5->hexdigest(),
		statusMD5 => $statusMD5->hexdigest(),
		employees => $employees,
	});
}


#
#
#
sub getLocations {
	my $s = shift;
	my $lParam = $s->param("loc");
	my $loc;

	if (defined($lParam)) {
		($loc) = $lParam =~ /([\d,]+)/;
	}

	if (!defined($loc)) {
		$loc = $s->db->selectall_arrayref("
			SELECT GROUP_CONCAT(location_id) FROM locations
		")->[0];
	}
	
	return $loc;
}

1;