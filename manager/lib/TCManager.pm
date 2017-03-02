package TCManager;

use Mojo::Base 'Mojolicious';
use TCManager::Helpers;
use Mojolicious::Plugin::Config;
use Data::Dumper;
use DBI;
use Mojo::Log;
use Mojolicious::Plugin::AccessLog;


sub startup {
    my $s = shift;

    my $conf = $s->plugin('Config', {
        file      => '/timeclock/manager/tcmanager.conf',
        stash_key => 'conf'
    });
    $s->helper(conf => sub { return $conf; });

    $s->helper(db => sub {
        return DBI->connect_cached(
            "dbi:mysql:$conf->{db_name}:$conf->{db_host}", 
            $conf->{db_user},
            $conf->{db_pass}
        );
    });

	$s->plugin(AccessLog => { log => $conf->{access_log} });

    my $log = Mojo::Log->new();
    $s->helper(log => sub { return $log; });

    $s->plugin('TCManager::Helpers');

    $s->sessions->default_expiration(60 * 60 * $conf->{session_time});
    $s->sessions->cookie_name($conf->{session_cookie_name});
    $s->secrets([$conf->{session_secret}]);
    $s->mode($conf->{app_mode});

    my $r = $s->routes;
    $r->route('/signin')->via('get') ->to('auth#signin');
    $r->route('/signin')->via('post')->to('auth#authenticate');
    $r->route('/error')->to('main#error');
    $r->route('/status')->to("extra#status");
    $r->route('/status/employees.json')->to('extra#employees');
    $r->route('/printFireDrill')->to('main#printFireDrill');
    $r->route('/punchy/signin')->via('get') ->to('punchy#signin');
    $r->route('/punchy/signin')->via('post')->to('punchy#authenticate');
    my $punchy_user = $r->under('/punchy')->to('punchy#is_authenticated');
    $punchy_user->route('/')->to('punchy#slash');
    $punchy_user->route('/main')->to('punchy#main');
    $punchy_user->route('/curTime.json')->to('punchy#curTime');
    $punchy_user->route('/punch')->to('punchy#punch');
    $punchy_user->route('/signout')->to('punchy#signout');    

    # only authenticated user will have access to these routes
    my $users_only = $r->under('/')->to('auth#is_authenticated');
    $users_only->route('/signout')->to('auth#signout');
    $users_only->route('/')->to('main#slash');
    $users_only->route('/main')->to('main#main');
    $users_only->route('/main/:empID/punch')->to('main#punch');
    $users_only->route('/main/massModify')->to('main#massModify');
    $users_only->route('/employee/:empID/markTardy/:inID')->to('employee#markTardy');
    $users_only->route('/employee/:empID/removeTardy/:tardyID')->to('employee#removeTardy');
    $users_only->route('/employee/:empID/removeTardy')->to('employee#removeTardy');
    $users_only->route('/employee/:empID/tardies')->to('employee#tardies');    
    $users_only->route('/employee/addPunch')->to('employee#addPunch');
    $users_only->route('/employee/modifyPunch')->to('employee#modifyPunch');
    $users_only->route('/employee/modifyHours')->to('employee#modifyHours');
    $users_only->route('/employee/:empID')->to('employee#main');
    $users_only->route('/employee/:empID/dayTimes/:dayOfPeriod')->to('employee#dayTimes');    
    $users_only->route('/employee/:empID/dayTimesByPunch/:punchID')->to('employee#dayTimesByPunch');
    $users_only->route('/employee/:empID/deletePunch/:inID/:outID')->to('employee#deletePunch');
    $users_only->route('/employee/:empID/punch')->to('employee#punch');
    $users_only->route('/employee/:empID/punchDetails/:punchID')->to('employee#punchDetails');
    $users_only->route('/setperiod/:period')->to('main#setPeriod');
    $users_only->route('/setperiod/timestamp/:timestamp')->to('main#setPeriodByTimestamp');
    $users_only->route('/setperiod/date/:date')->to('main#setPeriodByDate');
    $users_only->route('/chart/totalsHistory/:empID')->to('chart#cTotalsHistory');
    $users_only->route('/chart/periodPunches/:empID')->to('chart#cPeriodPunches');
    $users_only->route('/chart/periodSummary/:empID')->to('chart#cPeriodSummary');
    $users_only->route('/chart/employeeList')->to('chart#cEmployeeList');
    $users_only->route('/report/modifiedPunches')->to('report#modifiedPunches');
    $users_only->route('/report/fireDrill')->to('report#fireDrill');
    $users_only->route('/report/totals')->to('report#totals');
    $users_only->route('/report/detailed')->to('report#detailed');
    $users_only->route('/report/tardies')->to('report#tardies');

    my $admins_only = $r->under('/')->to('auth#is_admin');
    $admins_only->route('/admin/upload')->via('get')->to('admin#upload');
    $admins_only->route('/admin/upload')->via('post')->to('admin#sendToAS400');
    $admins_only->route('/admin/download')->via('get')->to('admin#download');
    $admins_only->route('/admin/download')->via('post')->to('admin#makeHoursCSV');
    $admins_only->route('/admin/punchReasons')->to('admin#punchReasons');
    $admins_only->route('/admin/punchReasons/remove/:id')->to('admin#removePunchReason');
    $admins_only->route('/admin/punchReasons/add')->to('admin#addPunchReason');
    $admins_only->route('/admin/tardyReasons')->to('admin#tardyReasons');
    $admins_only->route('/admin/tardyReasons/remove/:id')->to('admin#removeTardyReason');
    $admins_only->route('/admin/tardyReasons/add')->to('admin#addTardyReason');
    $admins_only->route('/admin/holidays')->to('admin#holidays');
    $admins_only->route('/admin/holidays/remove/:id')->to('admin#removeHoliday');
    $admins_only->route('/admin/holidays/add')->to('admin#addHoliday');
    $admins_only->route('/admin/accounts')->to('admin#accounts');
    $admins_only->route('/admin/accounts/delete/:id')->to('admin#deleteAccount');
    $admins_only->route('/admin/accounts/edit')->to('admin#editAccount');
    $admins_only->route('/admin/accounts/edit/access')->to('admin#editAccountAccess');
    $admins_only->route('/admin/accounts/add')->to('admin#addAccount');
    $admins_only->route('/admin/accounts/:id')->to('admin#accountDetails');
    $admins_only->route('/admin/accounts/access/:id')->to('admin#accountAccess');
    $admins_only->route('/admin/employees')->to('admin#employees');
    $admins_only->route('/admin/employees/edit/:id')->to('admin#editEmployee');
    $admins_only->route('/admin/employees/delete/:id')->to('admin#deleteEmployee');
    $admins_only->route('/admin/employees/save')->to('admin#saveEmployee');
    $admins_only->route('/admin/employees/new')->to('admin#newEmployee');
    $admins_only->route('/admin/employees/add')->to('admin#addEmployee');
    $admins_only->route('/admin/restoreEmployee/:empID')->to('admin#restoreEmployee');
}

1;
