package TCManager::Punchy;

#
# Punchy is the website the the employees can access to view time and punch in and out.
#

use Date::Calc qw/Date_to_Time/;
use Mojo::Base 'Mojolicious::Controller';
use Authen::Simple::ActiveDirectory;
use Data::Dumper;
use LWP::Simple;
use JSON;


#
# Verifies that the logged in user is valid
#
sub is_authenticated {
    my $s = shift;

    if ($s->session("punchyAuth") == 1 && $s->session("employee_id") =~ /\d+/) {
       return 1;
    }

    $s->redirect_to('/punchy/signin');
    return undef;
}


#
# Authenticate the user and store preferences
#
sub authenticate {
    my $s    = shift;
    my $user = $s->param('user');
    my $pass = $s->param('pass');
    my $ad   = Authen::Simple::ActiveDirectory->new(
        host      => $s->conf->{ad_auth_host},
        principal => $s->conf->{ad_auth_principal},
    );

    unless ($user && $pass) {
        $s->flash(error => 'Need both a username and a password.');
        return $s->redirect_to('/punchy/signin');
    }

    my $emp = $s->db->selectrow_hashref("
    	SELECT employees.*, timezone
    	FROM employees
    		LEFT JOIN locations USING (location_id)
    	WHERE
    		active = TRUE AND
    		ad_name = ?
    ", {}, $user);

    if (!defined($emp)) {
        $s->flash(error => 'Unable to find that account.');
        return $s->redirect_to('/punchy/signin');
    }

    if ($emp->{ad_name} && $ad->authenticate($user, $pass)) {    	
        $s->session(
        	punchyAuth  => 1,
            employee_id => $emp->{employee_id},
            access      => $emp->{employee_id},
            admin       => 0,
            timezone    => $emp->{timezone},
            period      => $s->currentPeriod(),
        );
        return $s->redirect_to('/punchy/main');
    }

    $s->flash(error => 'Incorrect password.');
    return $s->redirect_to('/punchy/signin');
}


#
# Shows the login page. Could have a message flashed or stashed.
#
sub signin {
    my $s = shift;
    $s->render;
}


#
# Expire all user details and send back to the sign in page.
#
sub signout {
    my $s = shift;
    $s->session(expires => 1);
    return $s->redirect_to('/punchy/signin');
}


#
# Returns a timestamp with the database time in UTC.
#
sub curTime {
    my $s    = shift;
    my $time = $s->db->selectrow_arrayref("SELECT UNIX_TIMESTAMP()");
    $s->render(json => { timestamp => $time->[0] });
}


#
#
#
sub slash {
	return $_[0]->redirect_to("/punchy/main");
}


#
#
#
sub main {
	my $s = shift;
	my ($period) = $s->param("period") =~ /(\d+)/;
	$period //= $s->currentPeriod();

	my $empID = $s->session("employee_id");
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
		tardies => $tardies,
		period  => $period,
	);
}


#
#
#
sub punch {
	my $s      = shift;
	my $empID  = $s->session("employee_id");
	my $res    = decode_json( get($s->conf->{tcterminal_url} . "/punchFromPunchy/$empID") );
	my $period = $s->param("period") // $s->currentPeriod();
	$s->redirect_to("/punchy/main?period=$period");
}



1;
