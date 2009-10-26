#! /var/run/current-system/sw/bin/perl -w

use strict;
use feature 'switch';
use Hydra::Schema;
use Hydra::Helper::Nix;
use Hydra::Helper::AddBuilds;


STDOUT->autoflush();

my $db = openHydraDB;


sub fetchInputs {
    my ($project, $jobset, $inputInfo) = @_;
    foreach my $input ($jobset->jobsetinputs->all) {
        foreach my $alt ($input->jobsetinputalts->all) {
            my $info = fetchInput($db, $project, $jobset, $input->name, $input->type, $alt->value);
            push @{$$inputInfo{$input->name}}, $info if defined $info;
        }
    }
}


sub setJobsetError {
    my ($jobset, $errorMsg) = @_;
    eval {
        txn_do($db, sub {
            $jobset->update({errormsg => $errorMsg, errortime => time});
        });
    };
}


sub permute {
    my @list = @_;
    for (my $n = scalar @list - 1; $n > 0; $n--) {
        my $k = int(rand($n + 1)); # 0 <= $k <= $n 
        @list[$n, $k] = @list[$k, $n];
    }
    return @list;
}


sub checkJobset {
    my ($project, $jobset) = @_;
    my $inputInfo = {};
    
    # Fetch all values for all inputs.
    fetchInputs($project, $jobset, $inputInfo);

    # Evaluate the job expression.
    my ($jobs, $nixExprInput) = evalJobs($inputInfo, $jobset->nixexprinput, $jobset->nixexprpath);

    # Schedule each successfully evaluated job.
    my %currentBuilds;
    foreach my $job (permute @{$jobs->{job}}) {
        next if $job->{jobName} eq "";
        print "considering job " . $job->{jobName} . "\n";
        checkBuild($db, $project, $jobset, $inputInfo, $nixExprInput, $job, \%currentBuilds);
    }

    txn_do($db, sub {
        
        # Update the last checked times and error messages for each
        # job.
        my %failedJobNames;
        push @{$failedJobNames{$_->{location}}}, $_->{msg} foreach @{$jobs->{error}};

        $jobset->update({lastcheckedtime => time});
        
        foreach my $job ($jobset->jobs->all) {
            if ($failedJobNames{$job->name}) {
                $job->update({errormsg => join '\n', @{$failedJobNames{$job->name}}});
            } else {
                $job->update({errormsg => undef});
            }
        }

        # Clear the "current" flag on all builds that are no longer
        # current.
        foreach my $build ($jobset->builds->search({iscurrent => 1})) {
            $build->update({iscurrent => 0}) unless $currentBuilds{$build->id};
        }
        
    });
       
    # Store the errors messages for jobs that failed to evaluate.
    my $msg = "";
    foreach my $error (@{$jobs->{error}}) {
        my $bindings = "";
        foreach my $arg (@{$error->{arg}}) {
            my $input = $inputInfo->{$arg->{name}}->[$arg->{altnr}] or die "invalid input";
            $bindings .= ", " if $bindings ne "";
            $bindings .= $arg->{name} . " = ";
            given ($input->{type}) {
                when ("string") { $bindings .= "\"" . $input->{value} . "\""; }
                when ("boolean") { $bindings .= $input->{value}; }
                default { $bindings .= "..."; }
            }
        }
        $msg .= "at `" . $error->{location} . "' [$bindings]:\n" . $error->{msg} . "\n\n";
    }
    setJobsetError($jobset, $msg);
}


sub checkJobsetWrapped {
    my ($project, $jobset) = @_;
    
    print "considering jobset ", $jobset->name, " in ", $project->name, "\n";
    
    eval {
        checkJobset($project, $jobset);
    };
    
    if ($@) {
        my $msg = $@;
        print "error evaluating jobset ", $jobset->name, ": $msg";
        txn_do($db, sub {
            $jobset->update({lastcheckedtime => time});
            setJobsetError($jobset, $msg);
        });
    }
}


sub checkProjects {
    foreach my $project ($db->resultset('Projects')->search({enabled => 1})) {
        print "considering project ", $project->name, "\n";
        checkJobsetWrapped($project, $_)
            foreach $project->jobsets->search({enabled => 1});
    }
}


# For testing: evaluate a single jobset, then exit.
if (scalar @ARGV == 2) {
    my $projectName = $ARGV[0];
    my $jobsetName = $ARGV[1];
    my $jobset = $db->resultset('Jobsets')->find($projectName, $jobsetName) or die;
    checkJobsetWrapped($jobset->project, $jobset);
    exit 0;
}


while (1) {
    eval {
        checkProjects;
    };
    if ($@) { print "$@"; }
    print "sleeping...\n";
    sleep 30;
}
