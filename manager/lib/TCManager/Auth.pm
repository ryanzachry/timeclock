package TCManager::Auth;

use Mojo::Base 'Mojolicious::Controller';
use Crypt::Eksblowfish::Bcrypt qw/bcrypt/;
use Authen::Simple::ActiveDirectory;
use Data::Dumper;


#
# Verifies that the logged in user is valid.
#
sub is_authenticated {
    my $s = shift;

    if ($s->session("accountID")) {
       return 1;
    }

    $s->redirect_to("/signin?r=" . $s->req->url);
    return undef;
}


#
# Verifies user is logged in and an admin.
#
sub is_admin {
    my $s = shift;

    if ($s->session("admin") == 1) {
        return 1;
    }

    $s->flash(error => 'You are not an admin.');
    return $s->redirect_to('/error');
}


#
# Authenticates the user and store their preferences.
#
sub authenticate {
    my $s    = shift;
    my $user = $s->param('user');
    my $pass = $s->param('pass');

    my $ad = Authen::Simple::ActiveDirectory->new(
        host      => $s->conf->{ad_auth_host},
        principal => $s->conf->{ad_auth_principal},
		log       => $s->log
    );

    unless ($user && $pass) {
        $s->flash(error => 'Need both a username and a password.');
        return $s->redirect_to('/signin?r=' . $s->param("r"));
    }

    my $account = $s->db->selectrow_hashref("
        SELECT accounts.*, timezone 
        FROM accounts 
            LEFT JOIN locations USING (location_id)
        WHERE 
            active = TRUE AND
            user   = ?
    ", {}, $user);

    if (!defined($account)) {
        $s->flash(error => 'Unable to find that account.');
        return $s->redirect_to('/signin?r=' . $s->param("r"));
    }

    # Try to authenticate over Active Directory first, fall back to a local account.
	my $authOK = 0;
    if ($account->{auth_ad}) {
		if ($ad->authenticate($user, $pass)) {
			$authOK = 1;
		}
	}
	else {
    	# $account->{salt} contains full settings for bcrypt, null byte, cost and salt.
    	my $bcryptedPass = substr(bcrypt($pass, $account->{salt}), 29);
        if ($bcryptedPass eq $account->{pass}) {
			$authOK = 1;
		}
	}

	if ($authOK == 1) {
        $s->session(
            accountID  => $account->{account_id},
            user       => $account->{user},
            access     => $account->{access},
            admin      => $account->{admin},
            timezone   => $account->{timezone},
            period     => $s->currentPeriod(),
        );

        my $redirect = "/" . ($s->param("r") // "main");
        $redirect =~ s/^\/+/\//;
        return $s->redirect_to($redirect);
    }

    $s->flash(error => 'Incorrect password.');
    return $s->redirect_to('/signin?r=' . $s->param("r"));
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
    return $s->redirect_to('/signin');
}


1;
