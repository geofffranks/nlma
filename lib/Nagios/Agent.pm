package Nagios::Agent;

use warnings;
use strict;

use POSIX;
use Fcntl qw(LOCK_EX LOCK_NB);
use Cwd qw(abs_path);
use Sys::Hostname qw(hostname);

use Time::HiRes qw(gettimeofday usleep);
use YAML;

use Log::Log4perl qw(:easy);
use Log::Dispatch::Syslog;

our $VERSION = '1.1';

sub MAX { my ($a, $b) = @_; ($a > $b ? $a : $b); }
sub MIN { my ($a, $b) = @_; ($a < $b ? $a : $b); }

$| = 1;

use constant TICK => 1000;

# for check-in result
my @RUNTIMES = ();

sub daemonize
{
	my ($user, $group, $pid_file) = @_;

	DEBUG("daemonizing");

	open(SELFLOCK, "<$0") or die "Couldn't find $0: $!\n";
	flock(SELFLOCK, LOCK_EX | LOCK_NB) or die "Lock failed; is another nlma daemon running?\n";
	open(PIDFILE, ">$pid_file") or die "Couldn't open $pid_file: $!\n";
	my $uid = getpwnam($user) or die "User $user does not exist\n";
	my $gid = getgrnam($group) or die "Group $group does not exist\n";

	setgid($gid) || die "Could not setgid to $group group";
	setuid($uid) || die "Could not setuid to $user user";

	open STDIN,  "</dev/null" or die "daemonize: failed to reopen STDIN\n";
	open STDOUT, ">/dev/null" or die "daemonize: failed to reopen STDOUT\n";
	open STDERR, ">/dev/null" or die "daemonize: failed to reopen STDERR\n";

	chdir('/');

	exit if fork;
	exit if fork;

	usleep(1000) until getppid == 1;

	print PIDFILE "$$\n";
	close PIDFILE;
}

sub schedule_check
{
	my ($check) = @_;

	my $interval = $check->{interval};
	if ($check->{is_soft_state}) {
		$interval = $check->{retry};
	}

	$check->{next_run} = ($check->{started_at} || gettimeofday) + $interval;
	DEBUG("scheduled $check->{name} to run in $interval s at $check->{next_run}");
}

sub run_check
{
	my ($check, $root) = @_;

	my ($readfd, $writefd);
	pipe $readfd, $writefd;

	my $command = $check->{command};
	if (substr($command, 0, 1) ne "/") {
		if ($root) {
			$command = "$root/$command";
		} else {
			WARN("check $check->{name} has relative command, but no plugin_root specified!!");
		}
	}
	if ($check->{sudo}) {
		$command = "/usr/bin/sudo -n -u $check->{sudo} $command";
	}
	INFO("executing '$command' via /bin/sh -c");

	my $pid = fork();
	if ($pid < 0) {
		ERROR("fork failed for check $check->{name}");
		return undef;
	}

	if ($pid == 0) {
		my $name = "check $check->{name}";
		close STDERR;
		open STDERR, ">&", \*ERRLOG or WARN("$name STDERR reopen failed: ignoring check error output");

		close STDOUT;
		open STDOUT, ">&", \*$writefd or ERROR("$name STDOUT reopen failed: cannot get check output");

		close $readfd;
		close STDIN;

		exec("/bin/sh", "-c", $command) or do {
			FATAL("$name exec failed: $!");
			exit 42;
		}
	}

	$check->{started_at} = gettimeofday;
	$check->{ended_at} = 0;

	$check->{soft_stop} = $check->{started_at} + $check->{timeout};
	$check->{hard_stop} = $check->{soft_stop} + 2;

	$check->{sigterm} = $check->{sigkill} = 0;

	close $writefd;
	$check->{pipe} = $readfd;
	$check->{pid}  = $pid;

	INFO("running check $check->{name} pid $pid");
	DEBUG("check $check->{name} started_at = $check->{started_at}, soft_stop = $check->{soft_stop}, hard_stop = $check->{hard_stop}");

	return 1;
}

sub reap_check
{
	my ($check, $status) = @_;
	$check->{ended_at} = gettimeofday;
	$check->{duration} = $check->{ended_at} - $check->{started_at};
	$check->{exit_status} = (WIFEXITED($status) ? WEXITSTATUS($status) : -1);

	push @RUNTIMES, $check->{duration};

	# calculate hard / soft state (for retry logic)
	$check->{last_state} = $check->{state} unless $check->{is_soft_state};
	$check->{state} = $check->{exit_status};
	if ($check->{state} < 0 || $check->{state} > 3) {
		$check->{state} = 3; # UNKNOWN
	}

	$check->{current}++;
	# OK != soft; propgation of previous state != soft
	if ($check->{state} == 0 || $check->{state} == $check->{last_state}) {
		$check->{is_soft_state} = 0;
		$check->{current} = 1;

	} elsif ($check->{current} == $check->{attempts}) {
		$check->{is_soft_state} = 0;
		$check->{current} = 1;

	} else {
		$check->{is_soft_state} = 1;
	}

	DEBUG("check $check->{name} :: last_state:$check->{last_state}, state:$check->{state}, attempts:$check->{current}/$check->{attempts}, soft:$check->{is_soft_state}");
	schedule_check($check);

	$check->{pid} = -1;
	my $buf = "";
	my $n = read($check->{pipe}, $buf, 8192);
	close $check->{pipe};

	if (!defined $n) {
		ERROR("check $check->{name} encountered read error getting output: $!");
		return -1;
	}

	if ($check->{sigkill} || $check->{sigterm}) {
		$check->{exit_status} = 3; # UNKNOWN
		$buf = "check timed out";
	}
	my @l = split /[\r\n]/, $buf, 2;
	$buf = shift(@l) || '';
	$check->{output} = $buf eq "" ? "(no check output)" : $buf;

	$check->{pipe} = undef;

	DEBUG("check $check->{name} exited $check->{exit_status} with output '$check->{output}'");
	return 0;
}

sub send_nsca
{
	my ($parent, $cmd, $host, @checks) = @_;
	my ($address, $port) = split(/:/, $parent);

	my @command = (split(/\s+/, $cmd), "-H", $address, "-p", $port);
	DEBUG("send_nsca: executing ", join(' ', @command));

	pipe NSCA_READ, NSCA_WRITE;

	my $pid = fork();
	if ($pid < 0) {
		ERROR("failed to fork off send_nsca");
		return -1;
	}

	if ($pid == 0) {
		close NSCA_WRITE;
		close STDIN;
		open(STDIN, "<&NSCA_READ") or FATAL("send_nsca failed to reopen STDIN: $!");
		exec(@command) or do {
			FATAL("exec send_nsca failed: $!");
			exit 42;
		}
	}

	DEBUG("send_nsca: child $pid forked");
	close NSCA_READ;
	for my $c (@checks) {
		DEBUG("send_nsca: write '".join("\t", $host, $c->{name}, $c->{exit_status}, $c->{output})."'");
		print NSCA_WRITE join("\t", $host, $c->{name}, $c->{exit_status}, $c->{output})."\n";
	}
	close NSCA_WRITE;

	return $pid;
}

sub parse_config
{
	my ($file) = @_;

	DEBUG("parsing configuration in $file");

	open CONFIG, $file or return undef;
	my $yaml = join('', <CONFIG>);
	close CONFIG;

	my ($config, $checks) = Load($yaml);
	if (!exists $config->{hostname}) {
		$config->{hostname} = hostname;
		DEBUG("no config for hostname: using detected value of $config->{hostname}");
	}
	if (!exists $config->{user}) {
		$config->{user} = "icinga";
		DEBUG("no config for daemon user: using default of $config->{user}");
	}
	if (!exists $config->{group}) {
		$config->{group} = "icinga";
		DEBUG("no config for daemon group: using default of $config->{group}");
	}
	if (!exists $config->{pid_file}) {
		$config->{pid_file} = "/var/run/nlma.pid";
		DEBUG("no config for pid file: using default of $config->{pid_file}");
	}
	if (!exists $config->{parents}) {
		DEBUG("no config for parents: using default of {}");
		$config->{parents} = {default => []};
	} elsif (!exists $config->{parents}{default}) {
		DEBUG("no config for parents[default]: using default of []");
		$config->{parents}{default} = [];
	}
	if (!exists $config->{send_nsca}) {
		$config->{send_nsca} = "/usr/bin/send_nsca -c /etc/icinga/send_nsca.cfg";
		DEBUG("no config for send_nsca: using default of $config->{send_nsca}");
	}
	if (!exists $config->{timeout}) {
		$config->{timeout} = 30;
		DEBUG("no config for timeout: using default of $config->{timeout}s");
	}
	if (!exists $config->{interval}) {
		$config->{interval} = 300;
		DEBUG("no config for interval: using default of $config->{interval}s");
	}
	if (!exists $config->{plugin_root}) {
		DEBUG("no plugin_root configured; all check commands must be absolute paths!");
	}
	if (!exists $config->{dump}) {
		$config->{dump} = "/var/tmp";
		DEBUG("no config for dump directory: using default of $config->{dump}");
	}
	$config->{dump} = abs_path($config->{dump});

	if (!exists $config->{errlog}) {
		$config->{errlog} = "/var/log/nlma_error";
		DEBUG("no config for errlog: using default of $config->{errlog}");
	}
	$config->{errlog} = abs_path($config->{errlog});

	if (!exists $config->{startup_splay}) {
		$config->{startup_splay} = 15;
		DEBUG("no config for startup_splay: using default of $config->{startup_splay} seconds");
	}

	$config->{log} = $config->{log} || {};
	if (!exists $config->{log}->{facility}) {
		$config->{log}->{facility} = 'daemon';
		DEBUG("no syslog facility configured: using default of $config->{log}->{facility}");
	}
	if (!exists $config->{log}->{level}) {
		$config->{log}->{level} = 'error';
		DEBUG("no syslog level configured: using default of $config->{log}->{level}");
	}

	$config->{checkin} = $config->{checkin} || {};
	if (!exists $config->{checkin}->{interval}) {
		$config->{checkin}->{interval} = 300;
		DEBUG("no config for checkin interval: using default of $config->{checkin}->{interval}");
	}
	if (!exists $config->{checkin}->{service}) {
		$config->{checkin}->{service} = "nlma_checkin";
		DEBUG("no config for checkin service: using default of $config->{checkin}->{service}");
	}

	my @list = ();
	for my $cname (keys %$checks) {
		DEBUG("parsed check definition for $cname");
		my $check = $checks->{$cname};
		$check->{current} = 1; # current attempt

		# Use config key as name if not overridden
		$check->{name} = $check->{name} || $cname;

		# Default timeout of 30s
		$check->{timeout} = $check->{timeout} || $config->{timeout};

		# Default interval of 5 minutes
		$check->{interval} = $check->{timeout} || $config->{interval};

		# Default attempts of 1
		$check->{attempts} = $check->{attempts} || 1;

		# Default retry of 1 minute
		$check->{retry} = $check->{retry} || 60;

		# Use default check environment
		$check->{environment} = $check->{environment} || 'default';

		DEBUG("$cname name is '$check->{name}'");
		DEBUG("$cname environment is '$check->{environment}'");
		DEBUG("$cname command is '$check->{command}'");
		DEBUG("$cname interval is $check->{interval} seconds");
		DEBUG("$cname timeout is $check->{timeout} seconds");
		DEBUG("$cname attempts is $check->{attempts}");
		DEBUG("$cname retry interval is $check->{retry} seconds");

		$check->{started_at} = $check->{duration} = $check->{ended_at} = 0;
		$check->{next_run} = 0;
		$check->{current} = $check->{is_soft_state} = 0;
		$check->{last_state} = $check->{state} = 0;
		$check->{pid} = $check->{exit_status} = -1;
		$check->{output} = "";

		push @list, $check;
	}

	# Stagger-schedule the first run, longest interval runs first
	@list = sort { $b->{interval} <=> $a->{interval} } @list;
	my $run_at = gettimeofday;
	for my $check (@list) {
		$check->{next_run} = $run_at;
		$run_at += $config->{startup_splay};
	}

	return $config, \@list;
}

sub dump_config
{
	my ($config, $checks) = @_;

	my $file = "$config->{dump}/nlma.".gettimeofday().".yml";
	INFO("dumping config+checks to $file");

	my $fh;
	if (open $fh, ">$file") {
		print $fh Dump($config, $checks);
		close $fh;
	} else {
		ERROR("failed to dump config to $file: $!");
	}
}

sub merge_check_defs
{
	my ($old, $new) = @_;

	DEBUG("merging check definitions: ".scalar(@$old)." old, ".scalar(@$new));

	for my $check (@$old) {
		$check->{reconfiguring} = 1;
	}

	my @add = ();

	for my $newcheck (@$new) {
		my $found = 0;
		for my $oldcheck (@$old) {
			next unless $oldcheck->{name} eq $newcheck->{name};
			$found = 1;

			$oldcheck->{environment} = $newcheck->{environment};
			$oldcheck->{command}  = $newcheck->{command};
			$oldcheck->{interval} = $newcheck->{interval};
			$oldcheck->{timeout}  = $newcheck->{timeout};

			DEBUG("updating check definition for $oldcheck->{name}");

			if ($oldcheck->{pid} <= 0) {
				DEBUG("check $oldcheck->{name} not running; rescheduling");
				schedule_check($oldcheck);
			}

			delete $oldcheck->{reconfiguring};
			last;
		}

		if (!$found) {
			DEBUG("adding check definition for $newcheck->{name}");
			push @add, $newcheck;
		}
	}

	for my $check (@$old) {
		next unless $check->{reconfiguring};

		DEBUG("deleting check definition for $check->{name}");

		delete $check->{reconfiguring};
		$check->{deleted} = 1;
	}

	push @$old, @add;
	return 0;
}

sub waitall
{
	my ($config, $checks, $flags) = @_;
	my %results = ();

	while ( (my $child = waitpid(-1, $flags)) > 0) {
		my $status = $?;

		my $found = 0;
		for my $check (@$checks) {
			next unless $check->{pid} == $child;

			$found = 1;
			DEBUG("reaping child check process $child");
			reap_check($check, $?);
			unless ($check->{is_soft_state}) {
				my $env = $check->{environment};
				$results{$env} = [] unless $results{$env};
				push @{$results{$env}}, $check;
			}
			last;
		}

		if (!$found) {
			DEBUG("reaping child send_nsca process $child");
		}
	}

	for my $env (keys %results) {
		for my $parent (@{$config->{parents}{$env}}) {
			DEBUG("sending ".scalar(@{$results{$env}}). " results to $parent");
			send_nsca($parent, $config->{send_nsca}, $config->{hostname}, @{$results{$env}});
		}
	}
}

sub configure_syslog
{
	my ($logcfg) = @_; # the 'log' key of config
	Log::Log4perl::init({
		'log4perl.rootLogger'                => "DEBUG,SYSLOG",
		'log4perl.appender.SYSLOG'           => "Log::Dispatch::Syslog",
		'log4perl.appender.SYSLOG.min_level' => $logcfg->{level} || "warning",
		'log4perl.appender.SYSLOG.ident'     => 'nlma',
		"log4perl.appender.SYSLOG.facility"  => $logcfg->{facility} || "daemon",
		'log4perl.appender.SYSLOG.layout'    => "Log::Log4perl::Layout::PatternLayout",
		'log4perl.appender.SYSLOG.layout.ConversionPattern' => "[%P] %m",
	});
}

sub checkin
{
	my ($config) = @_;

	my $total_time = 0;
	my $avg_time = 0;
	my $nchecks = 0;

	if (@RUNTIMES) {
		for my $runtime (@RUNTIMES) {
			$total_time += $runtime
		}
		$nchecks = @RUNTIMES;
		$avg_time = sprintf("%0.3f", $total_time / 1000000 / $nchecks);
	}

	my $fake_check = {
		name => $config->{checkin}->{service},
		exit_status => 0,
		output => "$nchecks checks run, ${avg_time}s average runtime",
	};
	DEBUG("CHECKIN - $fake_check->{output}");

	for my $parent (@{$config->{parents}{default}}) {
		send_nsca($parent, $config->{send_nsca}, $config->{hostname}, $fake_check);
	}

	@RUNTIMES = ();
}

my $RECONFIG = 0;
sub sighup_handler { $RECONFIG = 1; }

my $TERM = 0;
sub sigterm_handler { $TERM = 1; }

my $DUMPCONFIG = 0;
sub sigusr1_handler { $DUMPCONFIG = 1; }

sub runall
{
	my ($class, $config_file) = @_;

	$config_file = abs_path($config_file);
	if (!-r $config_file) {
		print STDERR "$config_file: $!\n";
		exit 1;
	}

	my ($config, $checks) = parse_config($config_file);
	open ERRLOG, ">>", $config->{errlog};

	Log::Log4perl->easy_init($INFO);

	INFO("nlma v$VERSION starting up");
	INFO("configured to run ",scalar @$checks," checks");

	for my $check (@$checks) {
		INFO(">> running check $check->{name}");
		run_check($check, $config->{plugin_root});
	}
}

sub start
{
	my ($class, $config_file, $foreground) = @_;

	$config_file = abs_path($config_file);
	if (!-r $config_file) {
		print STDERR "$config_file: $!\n";
		exit 1;
	}

	my ($config, $checks) = parse_config($config_file);
	open ERRLOG, ">>", $config->{errlog};

	daemonize($config->{user}, $config->{group}, $config->{pid_file}) unless $foreground;
	configure_syslog($config->{log}) unless $foreground;

	INFO("nlma v$VERSION starting up");
	INFO("configured to run ",scalar @$checks," checks");

	$SIG{HUP}  = \&sighup_handler;
	$SIG{TERM} = \&sigterm_handler;
	$SIG{USR1} = \&sigusr1_handler;
	$SIG{PIPE} = "IGNORE";

	my $next_checkin = gettimeofday + $config->{checkin}->{interval};
	while (1) {
		last if $TERM;

		if ($RECONFIG) {
			INFO("SIGHUP caught; reconfiguring");
			$RECONFIG = 0;
			my ($newconfig, $newchecks) = parse_config($config_file);

			if ($newconfig->{errlog} ne $config->{errlog}) {
				close ERRLOG;
				open ERRLOG, ">>", $newconfig->{errlog};

			}
			$config = $newconfig;
			configure_syslog($config->{log}) unless $foreground;

			merge_check_defs($checks, $newchecks);
		}

		$checks = [grep { $_->{pid} > 0 || !exists $_->{deleted} } @$checks];

		if ($DUMPCONFIG) {
			$DUMPCONFIG = 0;
			INFO("SIGUSR1 caught; dumping config+checks");
			dump_config($config, $checks);
		}

		my $now = gettimeofday;
		if ($next_checkin < $now) {
			checkin($config);
			$next_checkin += $config->{checkin}->{interval};
		}
		for my $check (@$checks) {
			if ($check->{pid} > 0) {
				if ($check->{hard_stop} < $now && !$check->{sigkill}) {
					WARN("check $check->{name} pid $check->{pid} exceeded hard_stop; sending SIGKILL");
					$check->{sigkill} = 1;
					kill(KILL => $check->{pid});

				} elsif ($check->{soft_stop} < $now && !$check->{sigterm}) {
					WARN("check $check->{name} pid $check->{pid} exceeded soft_stop; sending SIGTERM");
					$check->{sigterm} = 1;
					kill(TERM => $check->{pid});

				}
			} else {
				next if $check->{deleted};

				if ($check->{next_run} < $now) {
					DEBUG("check $check->{name} next run $check->{next_run} < $now");
					run_check($check, $config->{plugin_root});
				}
			}
		}

		waitall($config, $checks, POSIX::WNOHANG);
		usleep(TICK);
	}

	if ($TERM) {
		INFO("SIGTERM caught; exiting");
		waitall($config, $checks);
	}
}

1;

=head1 NAME

Nagios::Agent - Nagios Local Check Agent

=head1 DESCRIPTION

The Nagios::Agent module implements the guts of the B<nlma> command.
Administrators looking to configure or use nlma should see nlma(1).

=head1 METHODS

=over

=item B<start($class, $config_file, $foreground)>

Initiates the Nagios::Agent scheduling loop, like this:

  Nagios::Agent->start("/etc/nlma.yml")

The $config_file argument will be turned into an absolute path if it
is not, so that SIGHUP reconfiguration still works when daemonized
(and CWD has changed to /).

Normal startup problems (i.e. unreadable / non-existent configuration
file) are caught early, and cause the process to exit with an exit code
of 1.

If $foreground is passed, and is a true value, the poller will run in
so-called "foreground" mode; all logging is done to stderr and the
process does not fork into the background.  See nlma(1) for details.

=item B<runall($class, $config_file)>

Ignore scheduling and run all configured checks, for testing.

  Nagios::Agent->runall("/etc/nlma.yml")

After each check has been run, it will not be re-scheduled.

=back

=head1 INTERNAL METHODS

=over

=item B<MAX($a, $b)>

Return the greater of two values.

=item B<MIN($a, $b)>

Return the lesser of two values.

=item B<daemonize>

Daemonize the process by forking into the background, closing all
file descriptors, and becoming a child of init(1)

=item B<schedule_check($check)>

Update the B<next_run> time for a check, based on the last time it
started execution, and its interval.

=item B<run_check($check, $root)>

Fork a child process, with a uni-directional pipe, and execute the
check plugin command.  This function is responsible for keeping
track of the child process' PID, and setting up the soft and hard
timeout deadlines.

If the check has been configured to run via sudo, the appropriate
sudo invocation (complete with -n) is constructed.

If $root is specified, it will be used as an absolute path to
prepend relative path command definitions.

=item B<reap_check($check, $status)>

Perform necessary accounting actions, like calculating check duration
and determining child output and exit code.  The $status variable
should come from the waitpid call, and tells reap_check if the check
exited of its own accord, or was killed (either by the Agent, or
some other signal).

This function handles various edge cases, including check runs that
created no output, and check runs that were killed because of timeouts.

=item B<send_nsca($parent, $cmd, $host, @checks)>

Fork a child process to submit results to a single Nagios parent via
send_nsca (specified by $cmd).  $host is the hostname of the local node,
which is used to inform the $parent which host these check results
pertain to.

=item B<parse_config($file)>

Parse the Nagios::Agent YAML configuration, supplying default values
where appropriate.  Returns two values, the global configuration and
an array of normalized check definitions.

=item B<dump_config($config, $checks)>

Dump configuration and scheduling data (usually in response to
SIGUSR1).  This function handles naming and creation of the dump
file.

=item B<merge_check_defs($old, $new)>

Merges check definitions (usually in response to reconfiguration via
SIGHUP).  This function handles the various edge cases to ensure
that check additions, updates and removals are processed properly,
even if a check is currently running.  $old and $new are array refs.

=item B<waitall($config, $checks, $flags)>

A refactoring, waitall waits for child processes to exit (either
check runs or send_nsca calls) and reacts accordingly.  Nothing is
done in response to a send_nsca child process terminating, but
check process termination is handled via a call to reap_check and
send_nsca.

The $flags arguments should either be undef, or POSIX::WNOHANG,
depending on whether it should wait for all child processes (i.e.
when terminating via SIGTERM) or just child processes that have
already exited (i.e. normal operation).

=item B<configure_syslog($logcfg)>

Configures the Log::Log4perl subsystem to send log messages to the
appropriate syslog facility.  Used at startup and during SIGHUP
reconfiguration (unless the Agent is running in foreground mode).

=item B<checkin($config)>

Run the built-in poller checkin logic, to report back to all parent
instances that the poller is in fact running, and to show what it
has been doing since it last checked in (number of checks run,
average run time, etc.).

=item B<sighup_handler>

=item B<sigterm_handler>

=item B<sigusr1_handler>

Signal handles for dealing with external control mechanisms.

=back

=head1 AUTHOR

Nagios::Agent was written by James Hunt <jhunt@synacor.com>

=cut