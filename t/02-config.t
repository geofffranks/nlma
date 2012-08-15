#!perl

use Test::More;
use Test::Deep;
use Nagios::Agent;

use Sys::Hostname qw(hostname);

{ # Default Configuration
	my ($config, $checks) = Nagios::Agent::parse_config('t/data/config/empty.yml');

	is($config->{hostname},  hostname, "<hostname> defaults to current node hostname");
	is($config->{user},      "icinga", "<user> default");
	is($config->{group},     "icinga", "<group> default");
	is($config->{pid_file},  "/var/run/nlma.pid", "<pid_file> default");
	is($config->{send_nsca}, "/usr/bin/send_nsca -c /etc/icinga/send_nsca.cfg", "<send_nsca> default");
	is($config->{timeout},   30, "<timeout> default");
	is($config->{interval},  300, "<interval> default");
	is($config->{startup_splay}, 15, "<startup_splay> default");
	is($config->{dump},      "/var/tmp", "<dump> default");

	is_deeply($config->{log}, {
			level => 'error',
			facility => 'daemon',
		}, "<log> default");
	is_deeply($config->{checkin}, {
			service => 'nlma_checkin',
			interval => 300,
		}, "<checkin> default");
	is_deeply($config->{parents}, {
			default => [],
		}, "<parents> default");
}

{ # Overridden Configuration
	my ($config, $checks) = Nagios::Agent::parse_config('t/data/config/full.yml');

	is($config->{hostname},  'fixed.host.example.com', "<hostname> override");
	is($config->{user},      "mon-user", "<user> override");
	is($config->{group},     "mon-group", "<group> override");
	is($config->{pid_file},  "/path/to/pid.file", "<pid_file> override");
	is($config->{send_nsca}, "/opt/other/send_nsca -c /etc/nsca.cfg", "<send_nsca> override");
	is($config->{timeout},   75, "<timeout> override");
	is($config->{interval},  240, "<interval> override");
	is($config->{startup_splay}, 17, "<startup_splay> override");
	is($config->{dump},      "/usr/share", "<dump> override");

	is_deeply($config->{log}, {
			level => 'info',
			facility => 'authpriv',
		}, "<log> override");
	is_deeply($config->{checkin}, {
			service => 'whats-up',
			interval => 123,
		}, "<checkin> override");
	is_deeply($config->{parents}, {
			default => [
				'df01.example.com',
				'df02.example.com',
			]
		}, "<parents> override");
}

{ # No default parents
	my ($config, $checks) = Nagios::Agent::parse_config('t/data/config/no-default-parents.yml');

	# Verify that if we specify parents, but forget the 'default' parents,
	# parse_config will Do The Right Thing (TM)

	is_deeply($config->{parents}, {
			default => [],
			prod => [
				'prod01.example.com',
				'prod02.example.com',
			],
			staging => [
				'stage01.example.com',
			],
		}, "<parents> default");
}

{ # Bad config file
	my ($config, $checks) = Nagios::Agent::parse_config('/path/to/nowhere');
	ok(!$config, "parse_config(BAD PATH) returns undef config");
	ok(!$checks, "parse_checks(BAD PATH) returns undef checks");
}

###################################################################

{ # Check configuration
	my $now = time;
	my ($config, $checks) = Nagios::Agent::parse_config('t/data/config/check-config.yml');

	is($config->{timeout},  33, "Default timeout is 33s");
	is($config->{interval}, 44, "Default interval is 44s");

	is(@$checks, 3, "Retrieved 3 checks from configuration");
	cmp_deeply([
			$checks->[0]{name},
			$checks->[1]{name},
			$checks->[2]{name},
		], [qw(check1 second_check check3)],
		"Ordered Checks");

	my $check;

	$check = $checks->[0];
	is($check->{name}, "check1", "<name> set properly");
	is($check->{timeout}, $config->{timeout}, "<timeout> default");
	is($check->{interval}, $config->{interval}, "<interval> default");
	is($check->{attempts}, 1, "<attempts> default");
	is($check->{retry}, 60, "<retry> default");
	is($check->{environment}, "default", "<environment> default");

	is($check->{started_at}, 0, "<started_at> is initially 0");
	is($check->{duration},   0, "<duration> is initially 0");
	is($check->{ended_at},   0, "<ended_at> is initially 0");
	is($check->{current},    0, "<current> attempt is initially 0");

	is($check->{is_soft_state}, 0, "<is_soft_state> is initially 0");
	is($check->{last_state},    0, "<last_state> is initially 0");
	is($check->{state},         0, "<state> is initially 0");

	is($check->{pid},         -1, "<pid> is initially -1 (invalid value)");
	is($check->{exit_status}, -1, "<exit_status> is initially -1 (invalid value)");

	is($check->{output}, "", "<output> is initially blank");

	cmp_ok($check->{next_run}, '>=', $now, "<next_run> is now or in the future");

	# Test that we overrode specific values for check2
	$check = $checks->[1];
	is($check->{name}, "second_check", "<name> overridden for check2");
	is($check->{interval}, 20, "<interval> overridden for check2");
	is($check->{timeout},   6, "<timeout> overridden for check2");
	is($check->{attempts},  4, "<attempts> overridden for check2");
	is($check->{retry},    11, "<retry> overridden for check2");
	is($check->{environment}, "dev", "<environment> overridden for check2");
}

{ # Check Splay
	my ($config, $checks) = Nagios::Agent::parse_config('t/data/config/check-splay.yml');

	is($config->{startup_splay}, 10, "Startup splay is 10 seconds");

	is(@$checks, 4, "Retrieved 4 checks from configuration");
	cmp_deeply([
			$checks->[0]{name},
			$checks->[1]{name},
			$checks->[2]{name},
			$checks->[3]{name},
		], [qw(check_raid check_mem check_disk check_cpu)],
		"Ordered Checks");

	my $start = $checks->[0]{next_run};
	cmp_ok($start, '>', time - 10, "First check scheduled to be run soon");
}

done_testing;