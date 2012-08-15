#!perl

use Test::More;
use Nagios::Agent;
use IO::String;
do "t/common.pl";

#  Tests in this suite only work because the reap_check function
#  doesn't really interact with a UNIX process; waitall does that.
#  Instead, it accepts a process exit status and a pipe to read
#  from.

my $NOW = time;

{ # Normal OK result

	my $check = mock_check({
			name => "check_ok",
			pipe => IO::String->new("all good"),
	});

	is(Nagios::Agent::reap_check($check, 0x0000), 0, "reap_check returns 0 on success");
	cmp_ok($check->{ended_at}, '>', $check->{started_at}, "check ended after it started");
	cmp_ok($check->{duration}, '>', 0, 'check duration was > 0');
	is($check->{is_soft_state}, 0, 'OK -> OK is not a soft state');
	is($check->{current}, 1, 'still on 1/1 attempts');
	is($check->{pid}, -1, 'check PID reset to -1');
	is($check->{output}, 'all good', 'read check output from pipe');
	ok(!$check->{pipe}, 'pipe closed and undefined');
	is($check->{state}, 0, "check state is now 0");
}

{ # Weird return values (>3)
	my $check = mock_check({
			name => 'bad_rc',
			pipe => IO::String->new("returned 0x34")
	});

	is(Nagios::Agent::reap_check($check, 0x3400), 0, "reap_check returns 0 on success");
	is($check->{state}, 3, "check state is now 3");
}

{ # Weird return values (KILLED or TERMED)
	my $check = mock_check({
			name => 'bad_rc',
			sigkill => 1,
			pipe => IO::String->new("non-local exit")
	});

	is(Nagios::Agent::reap_check($check, 0x3401), 0, "reap_check returns 0 on success");
	is($check->{state}, 3, "check state is now 3");
	is($check->{output}, "check timed out", 'KILLED should return timed-out output');
}

{ # No check output
	my $check = mock_check({
			name => 'no_output',
			pipe => IO::String->new('')
	});
	is(Nagios::Agent::reap_check($check, 0x0000), 0, "reap_check returns 0 on success");
	is($check->{output}, "(no check output)", "no output message");
}

{ # failed to read from pipe
	my $check = mock_check({
			name => 'bad_read',
			pipe => 'not-a-file-descriptor!'
	});
	diag "You should see a 'read() on unopened filehandle' warning below...";
	is(Nagios::Agent::reap_check($check, 0x0000), -1, "reap_check returns -1 on fail");
}

{ # Sustained Warning
	my $check = mock_check({
			name => 'warn_check',
			last_state => 1,
			state => 1,
			pipe => IO::String->new('still warning')
	});
	is(Nagios::Agent::reap_check($check, 0x0100), 0, "reap_check returns 0 on success");
	is($check->{is_soft_state}, 0, "WARNING -> WARNING is a hard state");
}

done_testing;