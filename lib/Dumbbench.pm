package Dumbbench;
use strict;
use warnings;
use Carp ();
use Time::HiRes ();

our $VERSION = '0.01';

require Dumbbench::Result;
require Dumbbench::Stats;
require Dumbbench::Instance;

use Params::Util '_INSTANCE';

use Class::XSAccessor {
  getters => [qw(
    target_rel_precision
    target_abs_precision
    initial_runs
    max_iterations
    variability_measure
    started
    outlier_rejection
  )],
  accessors => [qw(verbosity)],
};


sub new {
  my $proto = shift;
  my $class = ref($proto)||$proto;
  my $self;
  if (not ref($proto)) {
    $self = bless {
      verbosity            => 0,
      target_rel_precision => 0.05,
      target_abs_precision => 0,
      intial_runs          => 20,
      max_iterations       => 10000,
      variability_measure  => 'mad',
      instances            => [],
      started              => 0,
      outlier_rejection    => 2.5,
      @_,
    } => $class;
  }
  else {
    $self = bless {%$proto, @_} => $class;
    my @inst = $self->instances;
    $self->{instances} = [];
    foreach my $instance (@inst) {
      push @{$self->{instances}}, $instance->new;
    }
  }
  
  if ($self->target_abs_precision <= 0 and $self->target_rel_precision <= 0) {
    Carp::croak("Need either target_rel_precision or target_abs_precision > 0");
  }
  if ($self->initial_runs < 6) {
    Carp::carp("Number of initial runs is very small (<6). Precision will be off.");
  }
  
  return $self;
}

sub add_instances {
  my $self = shift;
  
  if ($self->started) {
    Carp::croak("Can't add instances after the benchmark has been started");
  }
  foreach my $instance (@_) {
    if (not _INSTANCE($instance, 'Dumbbench::Instance')) {
      Carp::croak("Argument to add_instances is not a Dumbbench::Instance");
    }
  }
  push @{$self->{instances}}, @_;
}

sub instances {
  my $self = shift;
  return @{$self->{instances}};
}

sub run {
  my $self = shift;
  Carp::croak("Can't re-run same benchmark instance") if $self->started;
  $self->dry_run_timings;
  $self->run_timings;
}

sub run_timings {
  my $self = shift;
  $self->{started} = 1;
  foreach my $instance ($self->instances) {
    next if $instance->result;
    $self->_run($instance);
  }
}

sub dry_run_timings {
  my $self = shift;
  $self->{started} = 1;

  foreach my $instance ($self->instances) {
    next if $instance->dry_result;
    $self->_run($instance, 'dry');
  }
}

sub _run {
  my $self = shift;
  my $instance = shift;
  my $dry = shift;

  # for overriding in case of dry-run mode
  my $V = $self->verbosity || 0;
  my $initial_timings = $self->initial_runs;
  my $abs_precision = $self->target_abs_precision;
  my $rel_precision = $self->target_rel_precision;
  my $max_iterations = $self->max_iterations;

  if ($dry) {
    $V--; $V = 0 if $V < 0;
    $initial_timings *= 5;
    $abs_precision    = 0;
    $rel_precision   /= 2;
    $max_iterations  *= 10;
  }

  print "Running initial timing for warming up the cache...\n" if $V;
  if ($dry) {
    # be generous, this is fast
    $instance->single_dry_run() for 1..3;
  }
  else {
    $instance->single_run();
  }
  
  my @timings;
  print "Running $initial_timings initial timings...\n" if $V;
  foreach (1..$initial_timings) {
    print "Running timing $_...\n" if $V > 1;
    push @timings, ($dry ? $instance->single_dry_run() : $instance->single_run());
  }

  print "Iterating until target precision reached...\n" if $V;

  my $stats = Dumbbench::Stats->new(data => \@timings);
  my $sigma;
  my $mean;

=for developers

My mental model for the distribution was Gauss+outliers.
Indeed, there's some Gaussian-like component to it, but at least at this low a level wrt. time span, systematic effects clearly dominate.
If my expectation had been correct, the following algorithm should produce a reasonable EV +/- uncertainty:
1) Calc. median of the whole distribution.
2) Calculate the median-absolute deviation from the whole distribution (MAD, see wikipedia). It needs rescaling to become a measure of variability that is robust against outliers.
(The MAD will be our initial guess for a "sigma")
3) Reject the samples that are outside $median +/- $n*$MAD.
I was expecting several high outliers but few lows. An ordinary truncated mean or the like would be unsuitable for removing the outliers in such a case since you'd get a significant upward bias of your EV.
By using the median as the initial guess, we keep the initial bias to a minimum. The MAD will be similarly unaffected by outliers AND the asymmetry.
Thus cutting the tails won't blow up the bias too strongly (hopefully).
4) Calculate mean & MAD/sqrt($n) of the remaining distribution. These are our EV and uncertainty on the mean.

=cut

  my $n_good = 0;
  my $variability_measure = $self->variability_measure;
  while (1) {
    $sigma = $stats->$variability_measure();# / sqrt(scalar(@timings));
    $mean  = $stats->mean();
    my $median = $stats->median();
    my $outlier_rejection = $self->outlier_rejection;
    my @t;
    if ($outlier_rejection) {
      @t = grep {abs($_-$median) < $outlier_rejection*$sigma} @timings;
    }
    else {
      @t = @timings; # doh
    }
    $n_good = @t;
    my $new_stats = Dumbbench::Stats->new(data => \@t);
    $sigma = $new_stats->$variability_measure() / sqrt(scalar(@t));
    $mean = $new_stats->mean();

    # stop condition
    my $need_iter = 0;
    if ($rel_precision > 0) {
      my $rel = $sigma/$mean;
      print "Reached relative precision $rel (neeed $rel_precision).\n" if $V > 1;
      $need_iter++ if $rel > $rel_precision;
    }
    if ($abs_precision > 0) {
      print "Reached absolute precision $sigma (neeed $abs_precision).\n" if $V > 1;
      $need_iter++ if $sigma > $abs_precision;
    }
    if ($n_good < $initial_timings) {
      $need_iter++;
    }
    last if not $need_iter or @timings == $max_iterations;

    push @timings, ($dry ? $instance->single_dry_run() : $instance->single_run());
  }

  if (@timings == $max_iterations and not $dry) {
    print "Reached maximum number of iterations. Stopping. Precision not reached.\n";
  }

  my $result = Dumbbench::Result->new(
    timing      => $mean,
    uncertainty => $sigma,
    nsamples    => $n_good,
  );

  if ($dry) {
    $instance->{dry_timings} = \@timings;
    $instance->dry_result($result);
  }
  else {
    $instance->{timings} = \@timings;
    $result -= $instance->dry_result if defined $instance->dry_result;
    $instance->result($result);
  }
}

sub report {
  foreach my $instance ($bench->instances) {
    my $result = $instance->result;
    
    if (not $RawOutput) {
      my $mean = $result->raw_number;
      my $sigma = $result->raw_error->[0];
      print "Ran " . scalar(@{$instance->timings}) . " iterations of the command.\n";
      print "Rejected " . (scalar(@{$instance->timings})-$result->nsamples) . " samples as outliers.\n";
      print "Rounded run time per iteration: $result" . sprintf(" (%.1f%%)\n", $sigma/$mean*100);
      print "Raw:                            $mean +/- $sigma\n" if $V;
    }
    else {
      print $result, "\n";
    }
  }
}

1;

__END__

=head1 NAME

Dumbbench - Perl extension more reliable benchmarking

=head1 SYNOPSIS

Command line interface: (See C<dumbbench --help>)

  dumbbench -p 0.005 -- ./testprogram --testprogramoption

This will start churning for a while and then prints something like:

  Ran 23 iterations of the command.
  Rejected 3 samples as outliers.
  Rounded run time per iteration: 9.519e-01 +/- 3.7e-03 (0.4%)

As a module:

  use Dumbbench;
  
  my $bench = Dumbbench->new(
    target_rel_precision => 0.005, # seek ~0.5%
    initial_runs         => 20,    # the higher the more reliable
  );
  $bench->add_instances(
    Dumbbench::Instance::Cmd->new(command => [qw(perl -e 'something')]), 
    # ... more things to benchmark ...
  );
  $bench->run;
  $bench->report;
  
=head1 DESCRIPTION

This module attempts to implement reasonably robust benchmarking with
little extra effort and expertise required from the user. That is to say,
benchmarking using this module is likely an improvement over

  time some-command --to --benchmark

or

  use Benchmark qw/timethis/;
  timethis(1000, 'system("some-command", ...)');

The module currently works similar to the former command line, except (in layman terms)
it will run the command many times, estimate the uncertainty of the result and keep
iterating until a certain user-defined precision has been reached. Then, it calculates
the resulting uncertainty and goes through some pain to discard bad runs and subtract
overhead from the timings. The reported timing includes an uncertainty, so that multiple
benchmarks can more easily be compared.

=head1 METHODS

In addition to the methods listed here, there are read-only
accessors for all named arguments of the constructor
(which are also object attributes).

=head2 new

Constructor that takes the following arguments (with defaults):

  verbosity            => 0,     # 0, 1, or 2
  target_rel_precision => 0.05,  # 5% target precision
  target_abs_precision => 0,     # no target absolute precision (in s)
  intial_runs          => 20,    # no. of guaranteed initial runs
  max_iterations       => 10000, # hard max. no of iterations
  variability_measure  => 'mad', # method for calculating uncertainty
  outlier_rejection    => 2.5,   # no. of "sigma"s for the outlier rejection

C<variability_measure> and C<outlier_rejection> probably make sense
after reading C<HOW IT WORKS> below.

=head2 add_instances

Takes one ore more instances of subclasses of L<Dumbbench::Instance>
as argument. Each of those is one I<benchmark>, really.
They are run in sequence and reported separately.

Right now, there's only one C<Dumbbench::Instance> implementation:
L<Dumbbench::Instance::Cmd> for running/benchmarking external commands.

=head2 run

Runs the dry-run and benchmark run.

=head2 report

Prints a short report about the benchmark results.

=head2 instances

Returns a list of all instance objects in this benchmark set.
The instance objects each have a C<result()> and C<dry_result()>
method for accessing the numeric benchmark results.

=head1 HOW IT WORKS AND WHY IT DOESN'T

=head2 Why it doesn't work and why we try regardless

Recall that the goal is to obtain a reliable estimate of the run-time of
a certain operation or command. Now, please realize that this is impossible
since the run-time of an operation may depend on many things that can change rapidly:
Modern CPUs change their frequency dynamically depending on load. CPU caches may be
invalidated at odd moments and page faults provide less fine-grained distration.
Naturally, OS kernels will do weird things just to spite you. It's almost hopeless.

Since people (you, I, everybody!) insist on benchmarking anyway, this is a best-effort
at estimating the run-time. Naturally, it includes estimating the uncertainty of the
run time. This is extremely important for comparing multiple benchmarks and that
is usually the ultimate goal. In order to get an estimate of the expectation value
and its uncertainty, we need a model of the underlying distribution:

=head2 A model for timing results

Let's take a step back and think about how the run-time of multiple
invocations of the same code will be distributed. Having a qualitative
idea what the distribution of many (B<MANY>) measurements looks like is
extremely important for estimating the expectation value and uncertainty
from a sample of few measurements.

In a perfect, deterministic, single-tasking computer, we will get N times the
exact same timing. In the real world, there are at least a million ways that
this assumption is broken on a small scale. For each run, the load of the
computer will be slightly different. The content of main memory and CPU
caches may differ. All of these small effects will make a given run a tiny
bit slower or faster than any other. Thankfully, this is a case where statistics (more precisely
the Central Limit Theorem) provides us with the I<qualitative> result: The
measurements will be normally distributed (i.e. following a Gaussian
distribution) around some expectation value (which happens to be the mean in this case).
Good. Unfortunately, benchmarks are more evil than that. In addition to the small-scale
effects that smear the result, there are things that (at the given run time of the benchmark)
may be large enough to cause a large jump in run time. Assuming these are
comparatively rare and typically cause extraordinarily long run-times (as opposed to
extraordinarily low run-times), we arrive at an overall model of
having a central, smooth-ish normal distribution with a few outliers towards
long run-times.

So in this model, if we perform C<N> measurements, almost all C<N> times
will be close to the expectation value and a fraction will be significantly higher.
This is troublesome because the outliers create a bias in the uncertainty
estimation and the asymmetry of the overall distribution will bias a simple
calculation of the mean.

What we would like to report to the user is the mean and uncertainty
of the main distribution while ignoring the outliers.

=head2 A robust estimation of the expectation value

Given the previously discussed model, we estimate the expectation value
with the following algorithm:

=over 2

=item 1)

Calculate the median of the whole distribution.
The median is a fairly robust estimator of the expectation value
with respect to outliers (assuming they're comparatively rare).

=item 2)

Calculate the median-absolute-deviation from the whole distribution
(MAD, see wikipedia). The MAD needs rescaling to become a measure
of variability. The MAD will be our initial guess for an uncertainty.
Like the median, it is quite robust against outliers.

=item 3)

We use the median and MAD to remove the tails of our distribution.
All timings that deviate by more than C<$X> times the MAD from the
median are rejected. This measure should cut outliers without introducing
much bias both in symmetric and asymmetric source distributions.

An alternative would be to use an ordinary truncated mean (that is
the mean of all timings while disregarding the C<$N> largest and C<$N>
smallest results). But the truncated mean can produce a biased result
in asymmetric source distributions. The resulting expectation value
would be artificially increased.

In summary: Using the median as the initial guess for the expectation value and the
MAD as the guess for the variability keeps the bias down in the general case.

=item 4)

Finally, the use the mean of the truncated distribution as the expectation
value and the MAD of the truncated distribution as a measure of variability.
To get the uncertainty on the expectation value, we take C<MAD / sqrt($N)> where
C<$N> is the number of remaining measurements.

=head2 Conclusion

I hope I could convince you that interpreting less sophisticated benchmarks
is a dangerous if not futile exercise. The reason this module exists is
that not everybody is willing to go through such contortions to arrive
at a reliable conclusion, but everybody loves benchmarking. So let's at least
get the basics right.  Do not compare raw timings of meaningless benchmarks but
robust estimates of the run time of meaningless benchmarks instead.

=head1 SEE ALSO

L<Benchmark>

L<http://en.wikipedia.org/wiki/Median_absolute_deviation>

=head1 AUTHOR

Steffen Mueller, E<lt>smueller@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2010 by Steffen Mueller

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.1 or,
at your option, any later version of Perl 5 you may have available.

=cut