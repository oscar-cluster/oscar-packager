package OSCAR::Packager;

#
# Copyright (c) 2009 Geoffroy Vallee <valleegr@ornl.gov>
#                    Oak Ridge National Laboratory
#                    All rights reserved.
#
#   $Id$
#
#   This program is free software; you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation; either version 2 of the License, or
#   (at your option) any later version.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program; if not, write to the Free Software
#   Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

#
# $Id$
#

BEGIN {
    if (defined $ENV{OSCAR_HOME}) {
        unshift @INC, "$ENV{OSCAR_HOME}/lib";
    }
}

use strict;
use Carp;
use vars qw($VERSION @EXPORT);
use base qw(Exporter);
use File::Basename;
use Data::Dumper;
use OSCAR::ConfigFile;
use OSCAR::Logger;
use OSCAR::OCA::OS_Detect;
use OSCAR::Utils;

@EXPORT = qw(package_opkg);

my $verbose = 1;

############################################################################
# Read in package_build config file.
# This is called build.cfg and should be located in the SRPMS directory.
# - matches the first header of the form [$distro:$version:$arch] that
#   fits the current machine
#
# Return: the lines of the matched block in an array, undef if error.
############################################################################
sub get_config {
    my ($path, $distro, $distver, $arch) = @_;
    local *IN;
    my ($line, $match, @config);

    open IN, "$path" or (carp "ERROR: Could not open $path: $!", return undef);
    while ($line = <IN>) {
        chomp $line;
        if ($line =~ /^\s*\[([^:]+):([^:]+):([^:]+)\]/) {
            my ($d,$v,$a) = ($1,$2,$3);
            $d =~ s/\*/\.*/g;
            $v =~ s/\*/\.*/g;
            $a =~ s/\*/\.*/g;
            my $str = "$distro:$distver:$arch";
            my $mstr = "($d):($v):($a)";
            $match = 0;
            if ($str =~ m/^$mstr$/) {
            $match = 1;
            print "found matching block [$d:$v:$a] for $distro:$distver:$arch\n" 
                if $verbose;
            last;
            }
        }
    }
    if ($match) {
        while ($line = <IN>) {
            chomp $line;
            last if ($line =~ /^\[([^:]+):([^:]+):([^:]+)\]/);
            next if ($line =~ /^\s*\#/);
            $line =~ s/^ *//g;
            next if ($line =~ /^$/);
            push @config, $line;
        }
    }
    close IN;
    if (@config) {
        return @config;
    } else {
        return undef;
    }
}

sub parse_build_file ($) {
    my $dir = shift;
    my @config;

    my $os = OSCAR::OCA::OS_Detect::open();
    if (!defined $os) {
        die "ERROR: Impossible to detect the binary package format";
    }

    # read in package build config file
    my $cfile = "$dir/build.cfg";
    if (-e $cfile) {
        @config = get_config($cfile,
                             $os->{compat_distro},
                             $os->{compat_distrover},
                             $os->{arch});
    } else {
        carp "ERROR: Build configuration file $cfile not found!";
        return undef;
    }
    return @config;
}

#########################
# Split up config lines into config blocks headed by requires lines.
# This allows multiple requires to be included in one opkg and
# the usage of requirements coming from the own opkg.
#
# The resulting array contains references to hashes with following structure:
# {
#   'requires' => requires_string, # requirements for current block
#   'common' => {                  # build results go to distro/common-rpms/
#                 'pkg_match1' => {       # match string (glob) for srpm name
#                                   'opt' => 'rpmbuild_additional_options'
#                                 },
#                 'pkg_match2' => {...},
#               },
#   'dist' => {                  # build results go to distro/$dist$ver-$arch/
#               'pkg_match3' => {       # match string (glob) for srpm name
#                                 'opt' => 'rpmbuild_additional_options'
#                               },
#               'pkg_match4' => {...},
#               ...
#             },
#   'env' => {
#               'variable' => value,
#            }
# },
#########################
sub split_config {
    my (@config_array) = @_;

    my @conf_blocks;
    my $conf = {};
    for (my $i = 0; $i <= $#config_array; $i++) {
        my $line = $config_array[$i];

        if ($line =~ /^(\S+)\s*(.*)\s*$/) {
            my $cmd = $1;
            my $data = $2;
            #my ($cmd,@data) = split(/\s+/,$line);
            if ($cmd =~ /^requires:/) {
                if (exists($conf->{requires}) ||
                (!exists($conf->{requires}) && $i > 0)) {
                    push @conf_blocks, $conf;
                    $conf = {};
                }
                $conf->{requires} = $data;
            } elsif($cmd =~ /^common:/) {
                my ($pkg,@data) = split(/\s+/,$data);
                $conf->{common}{"$pkg"}{opt} = join(" ",@data);
            } elsif($cmd =~ /^env:/) {
                if (exists($conf->{env})) {
                    $conf->{env} .= " $data";
                } else {
                    $conf->{env} = $data;
                }
            } elsif($cmd !~ /:$/) {
                $conf->{dist}{"$cmd"}{opt} = $data;
            }
        }
    }
    push @conf_blocks, $conf;

    print "conf_blocks:\n".Dumper(@conf_blocks)."\n============\n"
        if $ENV{OSCAR_VERBOSE};
    return @conf_blocks;
}

# This routine effectively create binary packages, hiding the differences 
# between RPMs and Debs.
#
# Return: -1 if error, 0 else.
sub create_binary ($$) {
    my ($s, $test) = @_;

    my $binaries_path = OSCAR::ConfigFile::get_value ("/etc/oscar/oscar.conf",
                                                      undef,
                                                      "OSCAR_SCRIPTS_PATH");

    my $os = OSCAR::OCA::OS_Detect::open();
    if (!defined $os) {
        carp "ERROR: Impossible to detect the binary package format";
        return -1;
    }

    my $cmd;
    if ($os->{pkg} eq "rpm") {
        $cmd = "$binaries_path/build_rpms --only-rpm $s";
        print "**** Executing: $cmd\n";
        if (!$test) {
            my $ret = system($cmd);
            if ($ret) {
            carp "ERROR: Command execution failed: $!";
            return $ret;
            } else {
                print "\nOK\n";
            }
        }
    } elsif ($os->{pkg} eq "deb") {
        carp "ERROR: Debian systems not yet supported";
        return -1;
    } else {
        carp "ERROR: $os->{pkg} is not currently supported";
        return -1;
    }

    return 0;
}

#
# Core binary package building routine
# - detects name and version-release from source rpms
# - checks whether rpms containing name/version already exist in the target dir
# - builds by calling build_rpms, adds build options from config file
# - all rpms resulting from build end up in the target directory
#
# Return: 0 if no error, else the number of errors during the build process.
sub build_if_needed {
    my ($confp, $pdir, $sel, $target) = @_;
    my ($march, $build_arch, $OHOME, $test, $err);

    OSCAR::Logger::oscar_log_subsection ("Building binary packages");

    my $env;
    my %conf = %{$confp};
    if (exists($conf{$sel})) {
#         &srpm_name_ver($pdir,$conf{$sel});

        print "== $sel ==\n".Dumper(%conf)."=====\n" if $verbose;

        # gather list of srpms which need to be built
        my (@sbuild,@buildopts);
        for my $g (keys(%{$conf{$sel}})) {
            print "key: $g\n";
            my $name = $conf{$sel}{"$g"}{name};
            my $ver = $conf{$sel}{"$g"}{ver};
            my $str = "$pdir/$target/$name-*$ver.{$march,noarch}.rpm";
            print "str: $str\n" if $verbose;
            my @gres = glob($str);
            if (!scalar(@gres)) {
                push @sbuild, $conf{$sel}{"$g"}{srpm};
                push @buildopts, $conf{$sel}{"$g"}{opt};
            } else {
                print "Found binary packages for $g:\n\t".join("\n\t",@gres).
                      "\nSkipping build.\n";
            }
        }
        if (exists($conf{env})) {
            $env = $conf{env};
        }
        if (@sbuild) {
            if (! -d "$pdir/$target") {
            print "Creating directory: $pdir/$target\n";
            !system("mkdir -p $pdir/$target")
                or croak("Could not create $target in $pdir: $!");
            }
            chdir("$pdir/$target");

            for my $s (@sbuild) {
            my $opt = shift @buildopts;
            if ($sel eq "common") {
                if ($opt !~ m,--target,) {
                    $opt .= " --target noarch";
                }
            } else {
                if ($opt !~ m,--target,) {
                    $opt .= " --target ".$build_arch;
                }
            }
            $ENV{RPMBUILDOPTS} = $opt;
            if ($opt) {
                print "setting \$RPMBUILDOPTS=$opt\n";
            }
            create_binary ($s, $test);
            }
        }
    }
    OSCAR::Logger::oscar_log_subsection ("Binary packages created");
    return $err;
}

################################################################################
# Install requires by invoking packman. Requires are remembered in the global  #
# array @installed_reqs, which is used for deleting them after the successful  #
# build.                                                                       #
#                                                                              #
# Input: requires, a string representing the list of binary packages to        #
#        install, package being separated by spaces.                           #
# Return: 0 if success, -1 else.                                               #
################################################################################
sub install_requires {
    my ($requires) = @_;

    OSCAR::Logger::oscar_log_subsection ("Installing requirements");

    if (!$requires) {
        OSCAR::Logger::oscar_log_subsection ("No requirements to install");
        return 0;
    }
    my $test = 0;
    my @installed_reqs = ();

    my @reqs = split(" ",$requires);
    print "Requires: ".join(" ",@reqs)."\n";

    my @install_stack;
    for my $r (@reqs) {
    if ($r =~ /^(.*):(.*)$/) {
        my $opkg = $1;
        my $pkg = $2;
        push (@install_stack, $pkg);
    } else {
        push (@install_stack, $r);
    }
    }
    if (!$test) {
        my %before;
        # TODO: create an abstraction to do based on both RPM and Debian tools.
#         # remember bianry packages which were installed before
#         my %before = map { $_ => 1 }
#                     split("\n",`rpm -qa --qf '%{NAME}.%{ARCH}\n'`);
        my $cmd = "/usr/bin/packman install ".join(" ",@install_stack);
        print "Executing: $cmd\n" if $verbose;
        if (system($cmd)) {
            print "Warning: failed to install requires: ".join(" ",@reqs)."\n";
        }
        # TODO: update that for both RPM and Debian
#         local *CMD;
#         open CMD, "rpm -qa --qf '%{NAME}.%{ARCH}\n' |" or do {
#             print "ERROR: Could not run rpm command\n";
#             return;
#             };
        while (<CMD>) {
            chomp;
            next if exists $before{$_};
            push @installed_reqs, $_;
        }
        close CMD;
        undef %before;
    }

    OSCAR::Logger::oscar_log_subsection ("Requirements installed");
    return 0;
}


# Input: pdir, where the OPKG source code is
#        confp, an array representing the build.cfg file for the OPKG.
# Return: 0 if success, -1 else.
sub build_binaries ($$) {
    my ($pdir,$confp) = @_;
    my ($err, $bindir);

    my @conf_blocks = &split_config(@$confp);

    for my $cblock (@conf_blocks) {
        my %conf = %{$cblock};

        # install requires
        if (install_requires($conf{requires})) {
            carp "ERROR: Impossible to install requirements";
            return -1;
        }

        # check and build common-rpms if needed
        $err = build_if_needed(\%conf,$pdir, "common", "distro/common");
        if ($err) {
            carp "ERROR: Impossible to build the OPKG ($pdir)";
            return -1;
        }

        # check and build dist specific binary packages if needed
        $err = build_if_needed(\%conf,$pdir,"dist",$bindir);
        if ($err) {
            carp "ERROR: Impossible to build the OPKG ($pdir)";
            return -1;
        }
    }

    return 0;
}


sub package_opkg ($) {
    my $build_file = shift;
    if (! -f ($build_file)) {
        carp "ERROR: Invalid path ($build_file)";
        return -1;
    }

    my $pdir = File::Basename::dirname ($build_file);;
    my $pkg = File::Basename::basename ($pdir);
    if (! -d $pdir) {
        carp "ERROR: Could not locate package location based on $build_file!\n";
        return -1;
    }
    if (!OSCAR::Utils::is_a_valid_string ($pkg)) {
        carp "ERROR: Impossible to get the OPKG name";
        return -1;
    }

    OSCAR::Logger::oscar_log_subsection "============ $pkg ===========";


    my @config = parse_build_file ($pdir);
    if (scalar (@config) == 0) {
        die "ERROR: Impossible to parse the build file";
    }

    OSCAR::Utils::print_array (@config);

    # main build routine
    my $err = build_binaries ($pdir,\@config);
# 
#     # remove installed requires
#     &remove_installed_reqs;

    OSCAR::Logger::oscar_log_subsection "=====================================";
    return 0;
}

__END__

=head1 Exported functions

=over 4

=item package_opkg ("/var/lib/oscar/package/c3/build.cfg");

Package a given OPKG.

=back

=head1 AUTHORS

=over 4

=item Erich Fotch

=item Geoffroy Vallee, Oak Ridge National Laboratory <valleegr at ornl dot gov>

=back

=cut