#!/usr/bin/perl
use strict;
use warnings;
use DBI;

my $db = DBI->connect_cached("DBI:mysql:time:db.host", "user", "pass");

my $accounts = $db->selectall_arrayref("
	SELECT * FROM accounts WHERE active = 1 AND admin = 0
	", { Slice => {} });

my $employees = $db->selectall_hashref("
	SELECT * FROM employees WHERE active = 1
	", "employee_id");

my $update = $db->prepare("UPDATE accounts SET access = ? WHERE account_id = ?");

for my $a (@$accounts) {
	my @cleanAccess;
	for (split(/,/, $a->{access})) {
		push(@cleanAccess, $_) if (exists($employees->{$_}));
	}

	$update->execute(join(",", @cleanAccess), $a->{account_id});
}