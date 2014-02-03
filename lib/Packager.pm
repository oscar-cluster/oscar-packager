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
use v5.10.1;
use Switch 'Perl5', 'Perl6';
use vars qw($VERSION @EXPORT);
use base qw(Exporter);
use Cwd;
use File::Basename;
use File::Copy;
use File::Path;
use OSCAR::Env;
use OSCAR::ConfigFile;
use OSCAR::Defs;
use OSCAR::FileUtils;
use OSCAR::Logger;
use OSCAR::LoggerDefs;
use OSCAR::OCA::OS_Detect;
use OSCAR::Utils;

our $force_nobuild;

@EXPORT = qw(
            available_releases
            package_opkg
            prepare_prereqs
            run_build_and_move
            parse_spec
            build_tarball_from_dir_spec
            force_nobuild
            update_repo
            );

our $verbose=0;
our $debug=0;
our $packaging_dir = "/tmp/oscar-packager";

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

    open IN, "$path" or (oscar_log(5, ERROR, "Could not open $path: $!"), return undef);
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
            oscar_log(6, INFO, "Found matching block [$d:$v:$a] for $distro:$distver:$arch"); 
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
        oscar_log(5, ERROR, "Unable to detect the binary package format");
        return undef;
    }

    # read in package build config file
    my $cfile = "$dir/build.cfg";
    if (-e $cfile) {
        @config = get_config($cfile,
                             $os->{compat_distro},
                             $os->{compat_distrover},
                             $os->{arch});
    } else {
        oscar_log(1, WARNING, "Build configuration file $cfile not found!");
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
            } elsif($cmd =~ /^nobuild:/) {
                if (exists($conf->{nobuild})) {
                    $conf->{nobuild} .= " $data";
                } else {
                    $conf->{nobuild} = $data;
                }
            } elsif($cmd !~ /:$/) {
                $conf->{dist}{"$cmd"}{opt} = $data;
            }
        }
    }
    push @conf_blocks, $conf;

    return @conf_blocks;
}

# Return: undef if error.
sub prepare_rpm_env ($$$$$) {
    my ($name, $os, $sel, $confp, $dest) = @_;

    #
    # We check the parameters
    #
    if (!defined ($confp) && ref($confp) ne "HASH") {
        oscar_log(5, ERROR, "Invalid configuration data");
        return undef;
    }
    if (!OSCAR::Utils::is_a_valid_string ($name)) {
        oscar_log(5, ERROR, "Invalid OPKG name");
        return undef;
    }
    if (!defined ($os)) {
        oscar_log(5, ERROR, "Invalid OS_Detect data");
        return undef;
    }
    if (! -d $dest) {
        oscar_log(5, ERROR, "Invalid destination");
        return undef;
    }

    my %conf = %{$confp};
    my $env;

    my $arch = $os->{arch};
    my $march = $arch;
    $march =~ s/^i.86$/i?86/;
    my $build_arch = $arch;
    $build_arch =~ s/^i.86$/i686/;

    # gather list of srpms which need to be built
    my (@sbuild, @buildopts);
    # we get data for the specific package from the config data
    my %data = %{${$conf{$sel}}{$name}};
    # TODO: we should check if the package is already there or not, but right
    # now i cannot get the package version.
#     my $name = $conf{$sel}{"$g"}{name};
#     my $ver = $conf{$sel}{"$g"}{ver};
#     my $str = "$dest/$name-*$ver.{$march,noarch}.rpm";
#     OSCAR::Logger::oscar_log_subsection "str: $str\n" if $verbose;
#     my @gres = glob($str);
#     if (!scalar(@gres)) {
        push @sbuild, $data{srpm};
        push @buildopts, $data{opt};
#     } else {
#         OSCAR::Logger::oscar_log_subsection "Found binary packages ".
#             "for $g:\n\t".join("\n\t",@gres).
#             "\nSkipping build.\n";
#     }
    if (exists($conf{env})) {
        $env = $conf{env};
    }
    if (! -d "$dest") {
        oscar_log(5, INFO, "Creating directory: $dest");
        eval { File::Path::mkpath ("$dest") };
        if ($@) {
            oscar_log(5, ERROR, "Couldn't create $dest: $@");
            return 1;
        }
    }
    # We move to this directory. This avoids to stay in destdir and try mv ./* to .
    chdir("$dest");

    my $opt = $data{opt};
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
        oscar_log(5, INFO, "Setting \$RPMBUILDOPTS=$opt...");
    }
    return $opt;
}

# This is a helper subroutine to move the built deb files to the 
# given output directory
#
# $fromdir: the dir were the deb have been generated (usually /tmp/oscar-packager/$name).
# $output: the destination (usualily the repo /tftpboot/oscar/<distroid>)
# $sel: either "common" or "dist"
#
# Return: -1 if error, 0 else.
sub move_debfiles($$$) {
    my ($fromdir, $output, $sel) = @_;
    if ( -d "$fromdir" ) {
        opendir( DIR, "$fromdir" ) || (oscar_log (1, ERROR, "Fail to opendir $fromdir : $!"), return -1);
        my @elmts = grep /.+\.deb$/, readdir DIR;
        closedir DIR; 
        foreach ( @elmts ) {
            oscar_log(4, INFO, "Moving " . File::Basename::basename ($_) . " to " . $output);
            File::Copy::copy ( "$fromdir/$_" , $output)
        }
    }
}

# This is a helper subroutine to parse the build command (rpm or deb) output,
# handle verbosity correctly and collect the packages generated if any.
#
# input:
# - $cmd: the command to run.
# - $output: the place to move resulting packages.
#
# output:
# - 0 success
# - -1 error
sub run_build_and_move($$) {
    my ($cmd,$output) = @_;
    my @pkgs= ();

    # Try to run the command and open the pipe.
    # Here, we get command not found errors.
    $ENV{LC_ALL} = 'C';
    unless (open(BUILD, "$cmd 2>&1 |")) {
        oscar_log(1, ERROR, "Failed to run build command: rc=$?.");
        oscar_log(5, ERROR, "       Failed command was: $cmd");
        return -1;
    }

    # Parse the output.
    my $output_line;
    while(<BUILD>) {
        $output_line=$_;
        chomp($output_line);
        if ($output_line =~ /Wrote: (.*\.rpm$)/) {
            push(@pkgs, $1);
        }
        if ($output_line =~ /^dpkg-deb: building package .* in `(.*\.deb)'.$/) {
            push(@pkgs, $1);
        }
        print "$output_line\n" if($OSCAR::Env::oscar_verbose >= 10);
    }

    # Close the pipe and check the return code.
    # Here, we get build fails errors.
    unless (close (BUILD)) {
        my $rc = $?/256;
        oscar_log(1, ERROR, "Failed to build package: rc=$rc.");
        oscar_log(5, ERROR, "  Failed command was: $cmd");
        return -1;
    }

    oscar_log(5, INFO, "Build finished.");

    # Now we move resulting packages to $output.
    if (scalar(@pkgs) == 0) {
        oscar_log(1, ERROR, "No package have been generated");
        oscar_log(5, ERROR, "       Command that did produce nothing was: $cmd");
        return -1;
    }
    foreach my $pkg (@pkgs) {
        chomp($pkg);
        if ( -f $pkg ) {
            # OL: FIXME: would better use perl(rename).
            $cmd = "mv -f $pkg $output";
            oscar_log(1, INFO, "Adding " . File::Basename::basename ($pkg) . " to " . File::Basename::basename ($output) . " repo");
            if (oscar_system ($cmd)) {
                return -1;
            }
        }
    }
    return 0
}

# This routine effectively create binary packages, hiding the differences 
# between RPMs and Debs.
#
# Return: -1 if error, 0 else.
sub create_binary ($$$$$$) {
    my ($basedir, $name, $conf, $sel, $test, $output) = @_;

    #
    # Get the OS informations
    #
    my $os = OSCAR::OCA::OS_Detect::open();
    if (!defined $os) {
        oscar_log(1, ERROR, "Unable to detect the binary package format");
        return -1;
    }

    #
    # Get, check or prepare the download dir.
    #
    my $download_dir = OSCAR::ConfigFile::get_value ("/etc/oscar/oscar.conf",
                                                     undef,
                                                     "PACKAGER_DOWNLOAD_PATH");
    $download_dir = "/var/lib/oscar-packager/downloads" if (! defined $download_dir);
    if (! -d $download_dir) {
        eval { File::Path::mkpath ($download_dir) };
        if ($@) {
            oscar_log(5, ERROR, "Couldn't create $download_dir: $@");
            return -1;
        }
    }
    my $build_dir = "$basedir";

    my $binaries_path = OSCAR::ConfigFile::get_value ("/etc/oscar/oscar.conf",
                                                      undef,
                                                      "OSCAR_SCRIPTS_PATH");
    # Is the config file for the package creation here or not?
    my $config_file = "$basedir/$name.cfg";
    my $build_cmd ="";
    if (! -f $config_file) {
        if($os->{pkg} eq "rpm") {
            # In the rpm-based system,
            # If the config file does not exist, we do not want to quit the program
            # but just proceed the build process with the given spec file.
            # OL: FIXME: Where is the source tarball in this situation???????? already in %{_sourcedir} ???

            # packaging_dir = /tmp/oscar-packager
            # spec files is in /tmp/oscar-packager/$name/rpm/$name.spec
            # or in /tmp/oscar-packager/$name/$name.spec
            my $spec_file = "$basedir/$name.spec";
            if (! -f $spec_file) {
                # Maybe the spec file is under the sub rpm directory?
                $spec_file = "$basedir/rpm/$name.spec";
            } 

            if (-f $spec_file) { # Native distro build material
                $build_cmd = "rpmbuild -bb $spec_file";
                # OL: FIXME. WHERE IS THE SOURCE??????

                # Set RPMBUILDOPTS according to build.cfg, $name, $os, $sel and $conf.
                # and chdir to $packaging_dir/$name.
                my $rpmbuild_options = prepare_rpm_env ($name, $os, $sel, $conf, $basedir);
                $build_cmd .= " $rpmbuild_options";
            } elsif ( -f "./Makefile" ) {
                # Else, if no spec file, then we try a make rpm if there is a Makefile.
                $build_cmd = "make rpm";
                oscar_log(4, INFO, "Building RPM package using make rpm");
            } else {
                oscar_log(5, ERROR, "There is no corresponding config file ($config_file), no spec file and no Makefile");
                return -1;
            }

            if (run_build_and_move($build_cmd,$output)) {
                return -1;
            }

        } elsif($os->{pkg} eq "deb") {
            # We try a dpkg-buildpackage if a debian/changelog file exists (just like for rpm if there is a spec file available).
            if ( -f "./debian/changelog" ) {
                $build_cmd = "dpkg-buildpackage -b -uc -us";
                $build_cmd .= " 1>/dev/null 2>/dev/null" if ($OSCAR::Env::oscar_verbose < 5);
                oscar_log(4, INFO, "Building DEB package using dpkg-buildpackage -b -uc -us");
            } elsif ( -f "./Makefile" ) {
                # Else, if no debian/changelog file, then we try a make deb if there is a Makefile.
                $build_cmd = "make deb";
                oscar_log(4, INFO, "Building DEB package using make deb");
            } else {
                oscar_log(5, ERROR, "There is no corresponding config file ($config_file), no debian dir and no Makefile");
                return -1;
            }

            if (run_build_and_move($build_cmd,$output)) {
                return -1;
            }
        } else {
            oscar_log(1, ERROR, "Unsupported packaging type: $os->{pkg}");
            return -1;
        }
        # Here, we produced a package; we can leave.
        return 0;
    }
    # ELSE: we have a config file for package.
 
    # SOURCES dir for package.(used for SRC_DIR precommand variable)
    my $src_dir="";
    switch ( $os->{pkg} ) {
        case "rpm" { chomp($src_dir = `/bin/rpm --eval %{_sourcedir}`) }
        case "deb" {
                       $src_dir="$basedir/debian";
                       mkdir $src_dir if (! -d $src_dir);
                   }
        # If not building rpm or deb, we work in basedir.
        else { $src_dir="$basedir" }
    }

    # Now, since we can access the config file, we parse it and download the
    # needed source files.
    oscar_log(4, INFO, "Downloading sources for $name...");
    my $source_data = OSCAR::ConfigFile::get_value ("$config_file",
                                                    undef,
                                                    "source");
    
    my $source_type = "";
    my $source_file = "";
    my @src_files = ();
    if($source_data){
        my ($method, $source) = split (",", $source_data, 2);
        if (OSCAR::FileUtils::download_file ($source,
                                             $download_dir,
                                             $method,
                                             OSCAR::Defs::NO_OVERWRITE())) {
            oscar_log(1, ERROR, "Failed to download the source file ($source)");
            return -1
        }
 
        @src_files = glob($source);

        # We assume that the main archive is the 1st source file.
        $source_file = File::Basename::basename ($src_files[0]);
        $source_type = OSCAR::FileUtils::file_type ("$download_dir/$source_file");

        if (!defined $source_type) {
            oscar_log(1, ERROR, "Unable to detect the source file format");
            return -1;
        }
    } else {
        # If no source is defined in the package config file, then we assume it is a tarball
        $source_type = OSCAR::Defs::TARBALL();
    }

    # RPMBUILDOPTS: We take the config value from the <package_name>.cfg file
    my $config_data = OSCAR::ConfigFile::get_value ("$config_file",
                                                    undef,
                                                    "config");
    chomp($config_data);

    # Prepare any precommand definded in a package's config file.
    # OSCAR::Logger::oscar_log_subsection "Running the preconfiigured commands for $name...";
    my $pre_cmd = OSCAR::ConfigFile::get_value ("$config_file",
                                                 undef,
                                                 "precommand");
    if($pre_cmd){
        $pre_cmd =~ s/BASE_DIR/$basedir/g;
        $pre_cmd =~ s/PKG_NAME/$name/g;
        $pre_cmd =~ s/SRC_DIR/$src_dir/g;

        # Prevent pollution if verbosity is lower than debug (10)
        # (between 6 and 10, we debug oscar-packager, not sub commands)
        $pre_cmd = "($pre_cmd) >/dev/null 2>/dev/null" if($OSCAR::Env::oscar_verbose < 10);
    }

    my $cmd;
    if ($os->{pkg} eq "rpm") {
        # Set RPMBUILDOPTS according to build.cfg, $name, $os, $sel and $conf.
        my $rpmbuild_options = prepare_rpm_env ($name, $os, $sel, $conf, $basedir);
        if ($source_type eq OSCAR::Defs::SRPM()) {
            oscar_log(4, INFO, "Building RPM from SRPM ".$source_file);
            # In this situation, the build environment is ready, we can run the precommand if any.
            if($pre_cmd){
                if (oscar_system($pre_cmd)) {
                     return -1;
                }
            }
             $cmd = "";
             $cmd = "echo TESTMODE:" if($test);
             $cmd .= "rpmbuild --rebuild $download_dir/$source_file $rpmbuild_options";
             $ENV{'RPMBUILDOPTS'} = $config_data if (defined ($config_data));
             if (run_build_and_move($cmd,$output)) {
                return -1;
             }
             $ENV{'RPMBUILDOPTS'} = "";
        } elsif ($source_type eq OSCAR::Defs::TARBALL()) {
            oscar_log(4, INFO, "Building RPM from TARBALL ".$source_file);
            my $build_cmd="rpmbuild";
            # We copy the source files in %{_sourcedir} (and spec files in .)
            foreach my $sf (@src_files){
                $sf = File::Basename::basename ($sf);
                # Check if it is a spec file
                if ($sf =~ m/.*\.spec/) {
                    # If yes, we copy the file in $basedir instead of $src_dir so it is found later.
                    # File::Copy::copy ("$download_dir/$sf", $basedir) 
                    if ( -e "$basedir/$sf" ) {
                        # If the file exists, remove it to prevent symlink to fail
                        unlink "$basedir/$sf";
                    }
                    symlink ("$download_dir/$sf", "$basedir/$sf") 
                        or (oscar_log(5, ERROR, "Unable to link the file ($download_dir/$sf, $basedir)"),
                            return -1);
                } else {
                    # Not a spec file, copy the source in $src_dir.
                    # File::Copy::copy ("$download_dir/$sf", $src_dir) 
                    if ( -e "$src_dir/$sf" ) {
                        # If the file exists, remove it to prevent symlink to fail
                        unlink "$src_dir/$sf";
                    }
                    symlink ("$download_dir/$sf", "$src_dir/$sf") 
                        or (oscar_log(5, ERROR,  "Unable to link the file ($download_dir/$sf, $src_dir)"),
                            return -1);
                }
            }

            # We try to copy the rpm additional sources that are in ./rpm/$name/ if any.
            if ( -d "$basedir/rpm/$name/" ) {
                opendir( DIR, "$basedir/rpm/$name/" ) || (oscar_log(5, ERROR, "Fail to opendir $basedir/rpm/$name : $!"), return -1);
                my @elmts = grep !/(?:^\.$)|(?:^\.\.$)/, readdir DIR;
                closedir DIR; 
                foreach ( @elmts ) {
                    File::Copy::copy ( "./rpm/$name/$_" , $src_dir)
                }
            }

            #
            # The build material is in place. In this situation, we can run the precommand if any.
            #
            if($pre_cmd){
                if (system($pre_cmd)) {
                     oscar_log(5, ERROR, "Unable to execute precommand: $pre_cmd");
                     return -1;
                }
            }
 
            # $basedir/rpm/$name.spec (from /etc/oscar/oscar-packager/*.cfg) has priority over
            # $basedir/$name.spec (from source in package.cfg or old svn config)
            my $spec_file = "$basedir/rpm/$name.spec";
            # We suppose that the specc file is provided from what has been downloaded from /etc/oscar/oscar-packager/*.cfg (often from svn)
            if (! -f $spec_file) {
                # If nothing is found, maybe it's downloaded from package.cfg source field, or from the above config file (old structure).
                $spec_file = "$basedir/$name.spec";
            }

            if ( -f $spec_file ) {
                # If we have a spec file (from @src_files or from ./rpm )
                # build the rpm using this spec file.
                oscar_log(4, INFO, "Building RPM package using provided spec file.");
                $build_cmd .= " -bb $spec_file";
            } else {
                # No spec file (either in @src_files or from ./rpm )
                # We try a tarbuild with the hope that there is a spec file inside the tarball.
                oscar_log(4, INFO, "Building RPM package using spec file from tarball.");
                $build_cmd .= " -tb $src_dir/$src_files[0]";
            }

            # Specify the target. old rpms were unable to build both architecture.
            # For those rpms, we use the common: tag. Thus 2 build occures:
            # one with --target=noarch and one without (arch build).
            # On modern rpms, both arch and noarch sub rpms will be generated
            # When rpmbuild is called without --target. For those modern rpms, there
            # is no common: section in build.cfg.
            #
            # Line below useless for the moment:
            # $build_cmd .= " --target noarch " if ("$sel" eq "common");

            $build_cmd .= " $rpmbuild_options";

            if (run_build_and_move($build_cmd,$output)) {
                return -1;
            }
        } else {
            # On RPM distro, we support only SRPM or TARBALL.
            # FIXME: We should try "make rpm" here.
            oscar_log(1, INFO, "Building RPM from unsupported file type ".$source_file);

            #
            # The build material is in place. In this situation, we can run the precommand if any.
            #
            if($pre_cmd){
                if (oscar_system($pre_cmd)) {
                     oscar_log(1, ERROR, "ERROR: Unable to execute precommand: $pre_cmd");
                     return -1;
                }
            }
            oscar_log(1, ERROR, "Unsupported file type for binary package creation ($source_type)");
            return -1;
        }
        oscar_log(1, INFO, "$name rpm(s) successfully built.");
    } elsif ($os->{pkg} eq "deb") {
        if ($source_type eq OSCAR::Defs::TARBALL()) {

            oscar_log(4, INFO, "Building DEB from TARBALL ".$source_file);

            # OL FIXME: having extract file returning a list of new objects in $dest would be more reliable).
            # Try to guess the name of the extracted directory.
            my ($extracted_dir, $sourcepath, $suffix) = File::Basename::fileparse($source_file, qr/.tar.gz|.tar.bz2|.tgz|.tbz/);

            # We extract the source_file and cd to basedir.
            if (extract_file("$download_dir/$source_file","$basedir")) {
                oscar_log(1, ERROR, "Unable to extract $source_file\nFalling back to make deb method.");
                # Can't extract, we'll fall back to "make deb"
            } else {
                if ( -d "$basedir/$extracted_dir/" ) {
                    # Good guess.
                    # 1st, we check if there is a debian/ dir in the extracted archive.
                    if ( -d "$basedir/$extracted_dir/debian" ) {
                        oscar_log(4, INFO, "Found debian/ directory in $source_file. I'll use this to build the package.");
                    } else {
                        # 2nd, if no debian/ dir, then we try to copy our debian directory if any in the extracted archive.
                        # We try to copy the debian build material that is in ./debian if any.
                        # FIXME: We should copy recursively filtering .svn stuffs using Xcopy
                        if ( -d "$basedir/debian/" ) {
                            opendir( DIR, "$basedir/debian/" ) || (oscar_log(5, ERROR, "Fail to opendir $basedir/debian : $!"), return -1);
                            my @elmts = grep !/(?:^\.$)|(?:^\.\.$)|(?:.svn)/, readdir DIR;
                            closedir DIR; 
                            mkdir "$basedir/$extracted_dir/debian";
                            foreach ( @elmts ) {
                                File::Copy::copy ( "$basedir/debian/$_" , "$basedir/$extracted_dir/debian/")
                            }
                        }
                    }
                } else {
                    oscar_log(4, WARNING, "No debian/ directory found in $source_file. I'll use the make deb method to build the package.");
                }
            }

            #
            # The build material is in place. In this situation, we can run the precommand if any.
            #
            if($pre_cmd){
                if (system($pre_cmd)) {
                     oscar_log(1, ERROR, "Unable to execute precommand: $pre_cmd");
                     return -1;
                }
            }
            # if we have a debian/control file we try to build the package

            # FIXME: use run_build_and_move() here. (be carfull with working directory).
            my $current_directory = `pwd`;
            chomp($current_directory);
            chdir "$basedir/$extracted_dir";
            if ( -f "debian/changelog" ) {
                $cmd = "dpkg-buildpackage -b -uc -us";
                oscar_log(4, INFO, "Building DEB package using dpkg-buildpackage -b -uc -us");
            } else {
                # Else, if no debian/control file, then we try a make deb.
                $cmd = "make deb";
                oscar_log(4, INFO, "Building DEB package using 'make deb'");
            }
            if (run_build_and_move($cmd,$output)) {
                return -1;
#            } else {
#                # Build succeeded, avoid future build attempt (Make build from main)
#                oscar_system("touch $basedir/build.stamp");
            }
            chdir "$current_directory"
                or oscar_log(5, ERROR, "Failed to move back to $current_directory after build");

#            # Now, we need to move *.deb to dest.
#            move_debfiles($basedir, $output, $sel);
            oscar_log(1, INFO, "$name deb(s) successfully built.");
        } else {
            # For unsupported source type (srpm, svn), we try the precommand. It could do the trick.....
            oscar_log(4, INFO, "Building DEB from unsupported archive type (".$source_type.") from ".$source_file);
            #
            # The build material is in place. In this situation, we can run the precommand if any.
            #
            if($pre_cmd){
                if (oscar_system($pre_cmd)) {
                     oscar_log(1, ERROR, "Unable to execute precommand: $pre_cmd");
                     return -1;
                }
            } else {
                # No precommand and unsupported source type means nothing is built.
                oscar_log(1, ERROR, "Unsupported file type for binary package creation ($source_type)");
                return -1;
            }
            oscar_log(1, WARNING, "Build for unsupported source type was attempted. The precommand was successful Though\n" .
                  "          Please check that the build occured");
        }
    } else {
        oscar_log(1, ERROR, "Packaging system '$os->{pkg}' is not currently supported");
        return -1;
    }

    return 0;
}

################################################################################
# Core binary package building routine
# - detects name and version-release from source rpms
# - checks the binary package(s) already exist in the target dir
# - builds by calling create_binary, adds build options from config file
# - all binary packages resulting from build end up in the target directory
#
# Return: err: 0 if no error, else the number of errors during the build process.
#         build_attempts: number of build attemps during this step.
#                         (can be 0 if build.cfg contains only requires:)
sub build_if_needed ($$$$) {
    my ($confp, $pdir, $sel, $target) = @_;
    my $build_attempts=0;
    my $test = 0;
    my $err = 0;

    my $env;
    my %conf = %{$confp};
    if (exists($conf{$sel})) {
#         &srpm_name_ver($pdir,$conf{$sel});

        for my $g (keys(%{$conf{$sel}})) {
            oscar_log(1, INFO, "Building $sel packages for $g.");
            if (create_binary ($pdir, $g, $confp, $sel, $test, $target)) {
                oscar_log(1, ERROR, "Failed to create the $sel package for $g.");
                $err++;
            }
            $build_attempts++;
        }
    }
    return ($err,$build_attempts++);
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
    my $return_code=0;

    oscar_log (4, SUBSECTION, "Installing requirements");

    if (!$requires) {
        oscar_log (5, INFO, "No requirements to install");
        return 0;
    }
    my $test = 0;
    my @installed_reqs = ();

    my @reqs = split(" ",$requires);
    oscar_log (5, INFO, "Requires: ".join(" ",@reqs));

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
    my $os = OSCAR::OCA::OS_Detect::open ();
    if (!defined $os && ref($os) ne "HASH") {
            oscar_log(5, ERROR, "Unable to detect the local distro");
            return -1;
        }
    my $distro_id = "$os->{distro}-$os->{distro_version}-$os->{arch}";
    
    # need to quote package as it can be 'perl(Pod::Man)'
    @install_stack = map { "'$_'" } @install_stack;
    my $cmd = "/usr/bin/packman install ".join(" ",@install_stack)." --distro $distro_id";
    $cmd .= " --verbose" if($OSCAR::Env::oscar_verbose >= 5);
    if (oscar_system($cmd)) {
        oscar_log(5, ERROR, "Failed to install requires: ".join(" ",@reqs));
        $return_code=-1;
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
    if ($return_code != 0) {
        return $return_code;
    } else {
        oscar_log(1, INFO, "Requirement(s): (".join(", ",@reqs).") installed.");
        return 0;
   }
}


# Input: pdir, where the source code is
#        confp, an array representing the build.cfg file for the software to package.
# Return: 0 if success, -1 else.
sub build_binaries ($$$) {
    my ($pdir, $confp, $output) = @_;
    my $err;
    my $number_of_common_builds=0;
    my $number_of_dist_builds=0;

    my @conf_blocks = split_config(@$confp);

    for my $cblock (@conf_blocks) {
        my %conf = %{$cblock};

        if ( defined $conf{nobuild} ) {
            if ( ! defined $OSCAR::Packager::force_nobuild ) {
                oscar_log(1, WARNING, "Skipping build:$conf{nobuild}");
                # We return one successfull build so oscar-packager don't try other build method.
                return 1;
            } else { # --ignore-nobuild is used. => We continue build process.
                oscar_log(1, INFO, "IGNORING 'nobuild:$conf{nobuild}'");
                # We do not return. We continue normal process just like of the nobuild tag was not present.
            }
        }

        # install requires
        if (install_requires($conf{requires})) {
            oscar_log(5, ERROR, "Failed to install requirements");
            return -1;
        }

        # check and build common-rpms if needed
        ($err,$number_of_common_builds) = build_if_needed(\%conf, $pdir, "common", $output);
        if ($err) {
            return -1;
        }

        # check and build dist specific binary packages if needed
        ($err,$number_of_dist_builds) = build_if_needed(\%conf, $pdir, "dist", $output);
        if ($err) {
            return -1;
        }
    }

    return ($number_of_common_builds+$number_of_dist_builds);
}

# Return: 0 if success, -1 else.
sub package_opkg ($$) {
    my ($build_file, $output) = @_;
    if (! -f ($build_file)) {
        oscar_log(5, ERROR, "Invalid path ($build_file)");
        return -1;
    }


    if (! -d $output) {
        oscar_log(5, ERROR, "Output directory does not exist ($output)");
        return -1;
    }

    my $pdir = File::Basename::dirname ($build_file);;
    my $pkg = File::Basename::basename ($pdir);
    if (! -d $pdir) {
        oscar_log(5, ERROR, "Could not locate package location based on $build_file!");
        return -1;
    }
    if (!OSCAR::Utils::is_a_valid_string ($pkg)) {
        oscar_log(5, ERROR, "Unable to get the OPKG name");
        return -1;
    }

#    oscar_log(1, SUBSECTION, "Packaging $pkg...");

    my @config = parse_build_file ($pdir);
    if (scalar (@config) == 0) {
        oscar_log(1, ERROR, "Unable to parse the build file");
        return -1;
    }

    oscar_log(6, INFO, "$build_file parsed:");
    OSCAR::Utils::print_array (@config) if($OSCAR::Env::oscar_verbose >= 6);

    # main build routine
    my $rc = build_binaries ($pdir, \@config, $output);

# 
#     # remove installed requires
#     &remove_installed_reqs;

    return $rc; # -1 if fail or # of build.(can be 0)
}

sub available_releases () {
    my $path = "/etc/oscar/oscar-packager";
    my @files = OSCAR::FileUtils::get_files_in_path ("$path");

    (oscar_log(1, ERROR, "Unable to scan $path"), return undef) if (scalar @files == 0);

    my @releases;
    foreach my $f (@files) {
        if ($f =~ m/^core_stable_(.*).cfg$/) {
            push (@releases, $1);
        }
    }

    return (@releases);
}

# This function deals with prereqs for the packaging of a given OSCAR 
# component. The management of prereqs is based on a build.cfg file at the top
# directory of the OSCAR component source tree. If the file does not exist, we
# assume there is no prereq to deal with.
#
# Return: -1 if error, 0 else.
sub prepare_prereqs ($$) {
    my ($dir, $output) = @_;

    $packaging_dir = $dir;

    my $build_file = "$dir/build.cfg";
    if (! -f "$build_file") {
        oscar_log(4, INFO, "No 'build.cfg', no prereqs to handle.");
        return 0; # 0 build occured here (not a failure).
    } else {
        oscar_log(4, INFO, "Processing ($build_file)");
        # we return the number of build that were attempted or -1 if a failure occured.
        return(package_opkg ($build_file, $output))
    }
}

################################################################################
=item build_tarball_from_dir_spec

Create an tarball from specified directory using filename computed from .pec file
found if any
Files are moved to a sub directory called %{name}-%{version}, then they are
put in the apropriate tarball (check archive type from spec file).

 Input: - directory containing sources.
        - spec file to use.

Return:  0: tarball name
        -1: undef

=cut
################################################################################

sub build_tarball_from_dir_spec($$) {
    my ($working_directory, $spec_file) = @_;

    if ( ! defined $working_directory || ! defined $spec_file) {
        oscar_log(5, ERROR, "working_directory or spec file undefined. API Error.");
        return undef;
    }


    # Now, move files into a directory that matches the Source: archive name
    # so %setup will be happy.
    
    my ($archive_dir, $ext_name) = parse_spec($spec_file);
    if (! defined $archive_dir || ! defined $ext_name) {
        oscar_log(5, ERROR, "Failed to parse $spec_file to retreive Source:");
        return undef;
    }
    my $archive_name = "$archive_dir"."$ext_name";

    my @files = glob("$working_directory/*"); # We get the list of files before creating the directory.
    mkdir "$working_directory/$archive_dir.$$";
    for my $file (@files) {        
        rename("$file","$working_directory/$archive_dir.$$/".basename($file))
            or oscar_log(5, WARNING, "Failed to move $file to $archive_dir.$$; Archive will be incomplete");
    }
    rename("$working_directory/$archive_dir.$$","$working_directory/$archive_dir");

    # Now, create the tarball in current directory.
    my $archive_command = "cd $working_directory; ";
    given ($ext_name) {
        when (/\.tar\.xz/) {
            $archive_command .= "tar cpJ --exclude=.svn -f $archive_name $archive_dir";
        }
        when (/\.tar\.bz2/) {
            $archive_command .= "tar cpj --exclude=.svn -f $archive_name $archive_dir";
        }
        when (/\.tar\.gz/) {
            $archive_command .= "tar cpz --exclude=.svn -f $archive_name $archive_dir";
        }
        when (/\.tar\.Z/) {
            $archive_command .= "tar cpZ --exclude=.svn -f $archive_name $archive_dir";
        }
        when (/\.tar$/) {
            $archive_command .= "tar cp --exclude=.svn -f $archive_name $archive_dir";
        }
        when (/\.zip/) {
            $archive_command .= "zip -r $archive_name $archive_dir --exclude .svn";
        }
        default {
            oscar_log(5, ERROR, "Archive format not supported for $archive_name");
            return 1;
        }
    }

    if(oscar_system($archive_command)) {
        oscar_log(5, ERROR, "Failed to create $archive_name");
        return undef;
    }

    # Now we have the archive in current directory.
    return "$working_directory/$archive_name";
}

sub parse_spec($) {
    my $spec_file = shift;

    if(! defined $spec_file) {
        oscar_log(5, ERROR, "specfile not defined");
        return (undef, undef);
    }
    if (! -f $spec_file) {
        oscar_log(5, ERROR, "$spec_file not found.");
        return (undef, undef);
    }
    my $dir_name = basename($spec_file, '.spec'); # Safe default value.
    my $archive_ext = '.tar.gz'; # Safe default value.

    unless (open SPEC, "<$spec_file") {
        oscar_log(5, ERROR, "Failed to open $spec_file for reading.");
        return undef;
    }

    my $source;
    while ( <SPEC> ) {
        if ( /^Source[0-9]*:\s*(.*)$/ ) {
            $source = $1;
            last;
        }
    }

    unless (close (SPEC)) {
        oscar_log(5, ERROR, "Failed to parse $spec_file (rc=" . $?/256 . ")");
    }

    if(! defined($source)) {
        oscar_log(5, WARNING, "No source found in specfile. Using default value: $dir_name.$archive_ext.");
        return($dir_name,$archive_ext);
    }

    chomp($source);

    # At this point, we have the source, but it can be of the form %{name}-%{version}.tar.bz2
    # So now, we need to run rpm spec interpretter to fix that.

	my $query_spec_cmd = "rpmspec -q ";

	# rpmspec is the replacement of rpm -q --specfile. Fallback to old method
	# if rpmspec not yet available. (assuming that rpmspec is always located at /usr/bin)
	$query_spec_cmd = "rpm -q --specfile " if ( ! -x '/usr/bin/rpmspec') ;

    $query_spec_cmd .= "--queryformat '$source\\n' $spec_file";
    oscar_log(7, ACTION, "About to run: $query_spec_cmd");
    unless (open(PARSE, "$query_spec_cmd |")) {
        oscar_log(5, ERROR, "Unable to parse $spec_file");
        oscar_log(5, WARNING, "Unable to retreive source filename from $spec_file. Using default value: $dir_name.$archive_ext.");
        return($dir_name,$archive_ext);
    }

    $source = <PARSE>; # Read only the 1st line (the relevant one).

    unless (close (PARSE)) {
        oscar_log(5, ERROR, "Failed to parse $spec_file (rc=" . $?/256 . ")");
        # next regexp test will check if we can still continue.
        # is source doesn't have lua variables, we may have a valind source-file name.
    }
    chomp($source);

    if($source =~ /.*%.*/) {
        oscar_log(5, ERROR, "Failed to evaluate '$source' using $spec_file. Using default value: $dir_name.$archive_ext.");
        return($dir_name,$archive_ext);
    }

    if($source =~ /^(.*)(.tar.xz|.tar.bz2|.tar.gz|.tar.Z|.tar|.zip)$/) {
        $archive_ext = $2;
        $dir_name = basename($1,(".tar.xz", ".tar.bz2", ".tar.gz", ".tar.Z", ".tar", ".zip"));
    } else {
        oscar_log(5, ERROR, "Found '$source' as source file, but it doesn't seems to be an archive. Using default values: $dir_name.$archive_ext.");
        return ($dir_name,$archive_ext);
    }

    return ($dir_name,$archive_ext);
}

sub update_repo($) {
    my $pkg_destdir = shift;
    my $cmd = "cd $pkg_destdir && /usr/bin/packman --prepare-repo $pkg_destdir";
    $cmd .= " 1>/dev/null 2>/dev/null" if ($OSCAR::Env::oscar_verbose < 5);
    $cmd .= " --verbose" if ($OSCAR::Env::oscar_verbose >= 5);
    if (oscar_system($cmd)) {
        oscar_log(1, ERROR, "Failed to update repository indexes.");
    } else {
        oscar_log(2, INFO, "$pkg_destdir repo index has been updated");
    }
}

1;
__END__

=head1 Exported functions

=over 4

=item package_opkg

Package a given OPKG. Example: package_opkg ("/usr/lib/oscar/package/c3/build.cfg");

=item available_releases

Returns the list of OSCAR releases that can be packaged. Example: my @oscar_releases = available_releases ();

=back

=head1 AUTHORS

=over 4

=item Erich Fotch

=item Geoffroy Vallee, Oak Ridge National Laboratory <valleegr at ornl dot gov>

=back

=cut
