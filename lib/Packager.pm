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
use Switch;
use vars qw($VERSION @EXPORT);
use base qw(Exporter);
use Cwd;
use File::Basename;
use File::Copy;
use File::Path;
use OSCAR::ConfigFile;
use OSCAR::Defs;
use OSCAR::FileUtils;
use OSCAR::Logger;
use OSCAR::OCA::OS_Detect;
use OSCAR::Utils;

@EXPORT = qw(
            available_releases
            package_opkg
            prepare_prereqs
            run_build_and_move
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

    return @conf_blocks;
}

# Return: undef if error.
sub prepare_rpm_env ($$$$$) {
    my ($name, $os, $sel, $confp, $dest) = @_;

    #
    # We check the parameters
    #
    if (!defined ($confp) && ref($confp) ne "HASH") {
        carp "ERROR: Invalid configuration data";
        return undef;
    }
    if (!OSCAR::Utils::is_a_valid_string ($name)) {
        carp "ERROR: Invalid OPKG name";
        return undef;
    }
    if (!defined ($os)) {
        carp "ERROR: Invalid OS_Detect data";
        return undef;
    }
    if (! -d $dest) {
        carp "ERROR: Invalid destination";
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
        OSCAR::Logger::oscar_log_subsection ("Creating directory: $dest");
        eval { File::Path::mkpath ("$dest") };
        if ($@) {
            carp "ERROR: Couldn't create $dest: $@";
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
        OSCAR::Logger::oscar_log_subsection ("Setting \$RPMBUILDOPTS=$opt...");
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
        opendir( DIR, "$fromdir" ) || die "Fail to opendir $fromdir : $!\n";
        my @elmts = grep /.+\.deb$/, readdir DIR;
        closedir DIR; 
        foreach ( @elmts ) {
            print "Moving " . File::Basename::basename ($_) . " to " . $output . "\n" if $verbose;
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
    $ENV{LC_ALL} = 'C';
    unless (open(BUILD, "$cmd 2>&1 |")) {
        print "ERROR: Failed to run build command: rc=$!.\n" if $verbose;
        print "       Failed command was: $cmd\n" if $debug;
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
        print "$output_line\n" if $debug;
    }

    # Close the pipe and check the return code.
    unless (close (BUILD)) {
        print "ERROR: Failed to build package: rc=$!.\n" if ($verbose);
        print "       Failed command was: $cmd\n";
        return -1;
    }

    # Now we move resulting packages to $output.
    if (scalar(@pkgs) == 0) {
        print "ERROR: No package have been generated\n";
        print "       Command that did produce nothing was: $cmd\n" if $debug;
        return -1;
    }
    foreach my $pkg (@pkgs) {
        chomp($pkg);
        if ( -f $pkg ) {
            $cmd = "mv -f $pkg $output";
            print "Moving " . File::Basename::basename ($pkg) . " to " . $output . "\n" if $verbose;
            OSCAR::Logger::oscar_log_subsection ("Executing: $cmd");
            if (system ($cmd)) {
                carp "ERROR: Impossible to execute $cmd";
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

    OSCAR::Logger::oscar_log_subsection ("Packaging $name");

    # We can sure the directory were we save downloads is ready
    # TODO: We should be able to specify that via a config file.
    my $download_dir = "/var/lib/oscar-packager/downloads";
#    my $build_dir = "/var/lib/oscar-packager/build";
    # Use $basedir = $packaging_dir/$name as $build_dir. ($pacjaging_dir = /tmp/oscar-packager)
    my $build_dir = "$basedir";

    my $binaries_path = OSCAR::ConfigFile::get_value ("/etc/oscar/oscar.conf",
                                                      undef,
                                                      "OSCAR_SCRIPTS_PATH");

    my $os = OSCAR::OCA::OS_Detect::open();
    if (!defined $os) {
        carp "ERROR: Impossible to detect the binary package format";
        return -1;
    }

    if (! -d $download_dir) {
        eval { File::Path::mkpath ($download_dir) };
        if ($@) {
            carp "ERROR: Couldn't create $download_dir: $@";
            return -1;
        }
    }

    # Is the config file for the package creation here or not?
    my $config_file = "$basedir/$name.cfg";
    if (! -f $config_file) {
        if($os->{pkg} eq "rpm"){
            # In the rpm-based system,
            # If the config file does not exist, we do not want to quit the program
            # but just proceed the build process with the given spec file.

            # packaging_dir = /tmp/oscar-packager
            # spec files is in /tmp/oscar-packager/$name/rpm/$name.spec
            # or in /tmp/oscar-packager/$name/$name.spec
            my $spec_file = "$basedir/$name.spec";
            if (! -f $spec_file) {
                $spec_file = "$basedir/rpm/$name.spec";
            } 
            my $build_cmd = "rpmbuild -bb $spec_file";

            # Set RPMBUILDOPTS according to build.cfg, $name, $os, $sel and $conf.
            # and chdir to $packaging_dir/$name.
            my $rpmbuild_options = prepare_rpm_env ($name, $os, $sel, $conf, $basedir);
            $build_cmd .= $rpmbuild_options;

            if (run_build_and_move($build_cmd,$output)) {
                print "ERROR: No rpms have been generated for package $name\n.";
                print "       Failed command (produced nothing) was: $build_cmd\n" if ($debug);
                return -1;
            }
            return 0;
        }
        if($os->{pkg} eq "deb"){
            # FIXME: We could try make deb.(in case a build_rpm with arball url is in a deb: rule).
            carp "ERROR: There is no corresponding config file: $config_file";
            return -1;
        }
    }

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

    # Run any precommand defind in a package's config file.
    OSCAR::Logger::oscar_log_subsection "Running the preconfiured commands for $name...";
    my $pre_cmd = OSCAR::ConfigFile::get_value ("$config_file",
                                                 undef,
                                                 "precommand");
    if($pre_cmd){
        $pre_cmd =~ s/BASE_DIR/$basedir/g;
        $pre_cmd =~ s/PKG_NAME/$name/g;
        $pre_cmd =~ s/SRC_DIR/$src_dir/g;
        if (system($pre_cmd)) {
             carp "ERROR: Impossible to execute $pre_cmd";
             return -1;
        }
    }

    # Now, since we can access the config file, we parse it and download the
    # needed source files.
    OSCAR::Logger::oscar_log_subsection "Downloading sources for $name...";
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
            carp "ERROR: Impossible to download the source file ($source)";
            return -1
        }
 
        # $source_file = File::Basename::basename ($source);
        # my $tmp_file = $source_file;
        # $tmp_file =~ s/[\{\}]//g;
        # @src_files = split(",", $tmp_file);
        # my $src_file = $src_files[0];

        @src_files = glob($source);

        # We assume that the main archive is the 1st source file.
        $source_file = File::Basename::basename ($src_files[0]);
        $source_type = OSCAR::FileUtils::file_type ("$download_dir/$source_file");

        if (!defined $source_type) {
            carp "ERROR: Impossible to detect the source file format";
            return -1;
        }
    } else {
        $source_type = OSCAR::Defs::TARBALL();
    }
    # We take the config value from the <package_name>.cfg file
    my $config_data = OSCAR::ConfigFile::get_value ("$config_file",
                                                    undef,
                                                    "config");
    chomp($config_data);

    my $cmd;
    if ($os->{pkg} eq "rpm") {
        # Set RPMBUILDOPTS according to build.cfg, $name, $os, $sel and $conf.
        my $rpmbuild_options = prepare_rpm_env ($name, $os, $sel, $conf, $basedir);
        if ($source_type eq OSCAR::Defs::SRPM()) {
            $cmd = "$binaries_path/build_rpms --only-rpm $download_dir/$source_file $rpmbuild_options";
            $cmd .= " --verbose" if $verbose;
            $ENV{'RPMBUILDOPTS'} = $config_data if (defined ($config_data));
            OSCAR::Logger::oscar_log_subsection "Executing: $cmd";
            if (!$test) {
                if (system($cmd)) {
                    carp "ERROR: Command execution failed: $! ($cmd)";
                    return -1;
                } 
            }
            $ENV{'RPMBUILDOPTS'} = "";
            # Resulting rpms are stored in the current directory.($basedir)
            $cmd = "mv ./*$name*.rpm $output";
            print "Executing: $cmd\n";
            if (system ($cmd)) {
                carp "ERROR: Impossible to execute $cmd";
                return -1;
            }
        } elsif ($source_type eq OSCAR::Defs::TARBALL()) {
            my $build_cmd="rpmbuild";
            # We copy the source files in %{_sourcedir} (and spec files in .)
            foreach my $sf (@src_files){
                $sf = File::Basename::basename ($sf);
                # Check if it is a spec file
                if ($sf =~ m/.*\.spec/) {
                    # If yes, we copy the file in $basedir instead of $src_dir so it is found later.
                    File::Copy::copy ("$download_dir/$sf", $basedir) 
                        or (carp "ERROR: impossible to copy the file ($download_dir/$sf, $basedir)",
                            return -1);
                } else {
                    # Not a spec file, copy the source in $src_dir.
                    File::Copy::copy ("$download_dir/$sf", $src_dir) 
                        or (carp "ERROR: impossible to copy the file ($download_dir/$sf, $src_dir)",
                            return -1);
                }
            }

            # We try to copy the rpm additional sources that are in ./rpm/$name/ if any.
            if ( -d "$basedir/rpm/$name/" ) {
                opendir( DIR, "$basedir/rpm/$name/" ) || die "Fail to opendir $basedir/rpm/$name : $!\n";
                my @elmts = grep !/(?:^\.$)|(?:^\.\.$)/, readdir DIR;
                closedir DIR; 
                foreach ( @elmts ) {
                    File::Copy::copy ( "./rpm/$name/$_" , $src_dir)
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
                print "[INFO] Building RPM package using provided spec file.\n" if $verbose;
                $build_cmd .= " -bb $spec_file";
            } else {
                # No spec file (either in @src_files or from ./rpm )
                # We try a tarbuild with the hope that there is a spec file inside the tarball.
                print "[INFO] Building RPM package using spec file from tarball.\n" if $verbose;
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

            $build_cmd .= $rpmbuild_options;

            $build_cmd .= " 1>/dev/null 2>/dev/null" if (!$debug);

            if (run_build_and_move($build_cmd,$output)) {
                print "ERROR: No rpms have been generated for package $name\n.";
                print "       Failed command (produced nothing) was: $build_cmd\n" if ($debug);
                return -1;
            }
        } else {
            # On RPM distro, we support only SRPM or TARBALL.
            # FIXME: We should try "make rpm" here.
            carp "ERROR: Unsupported file type for binary package creation ".
                 "($source_type)";
            return -1;
        }
    } elsif ($os->{pkg} eq "deb") {
        if ($source_type eq OSCAR::Defs::TARBALL()) {

            # OL FIXME: having extract file returning a list of new objects in $dest would be more reliable).
            # Try to guess the name of the extracted directory.
            my ($extracted_dir, $sourcepath, $suffix) = File::Basename::fileparse($source_file, qr/.tar.gz|.tar.bz2|.tgz|.tbz/);

            # We extract the source_file and cd to basedir.
            if (extract_file("$download_dir/$source_file","$basedir")) {
                print "WARNING: [create_package: extract_file] Impossible to extract $source_file\nFalling back to make deb method.\n" if $verbose;
                # Can't extract, we'll fall back to "make deb"
            } else {
                if ( -d "$basedir/$extracted_dir/" ) {
                    # Good guess.
                    # 1st, we check if there is a debian/control file in the extracted archive.
                    if ( -f "$basedir/$extracted_dir/debian/control" ) {
                        print "[INFO] Found debian/control in $source_file. I'll use this to build the package\n" if $verbose;
                    } else {
                        # 2nd, if no debian/control file, then we try to copy our debian directory if any in the extracted archive.
                        # We try to copy the debian build material that is in ./debian if any.
                        # FIXME: We should copy recursively filtering .svn stuffs using Xcopy
                        if ( -d "$basedir/debian/" ) {
                            opendir( DIR, "$basedir/debian/" ) || die "Fail to opendir $basedir/debian : $!\n";
                            my @elmts = grep !/(?:^\.$)|(?:^\.\.$)|(?:.svn)/, readdir DIR;
                            closedir DIR; 
                            mkdir "$basedir/$extracted_dir/debian";
                            foreach ( @elmts ) {
                                File::Copy::copy ( "$basedir/debian/$_" , "$basedir/$extracted_dir/debian/")
                            }
                        }
                    }
                } else {
                    print "[WARNING] no debian/control found in $source_file. I'll use the make deb method to build the package\n" if $verbose;
                }
            }

            # if we have a debian/control file we try to build the package
            if ( -f "$basedir/$extracted_dir/debian/control" ) {
                $cmd = "cd $basedir/$extracted_dir; dpkg-buildpackage -b";
                $cmd .= " 1>/dev/null 2>/dev/null" if (!$debug);
                print "[INFO] Building DEB package using dpkg-buildpackage -b\n" if $verbose;
            } else {
                # Else, if no debian/control file, then we try a make deb.
                $cmd = "make deb";
                print "[INFO] Building DEB package using make deb\n" if $verbose;
            }
            print "[DEBUG] About to run: $cmd\n" if $debug;
            if (system $cmd) {
                carp "ERROR: Impossible to execute $cmd";
                return -1;
            } else {
		# Build succeeded, avoid future build attempt (Make build from main)
                system "touch $basedir/build.stamp";
            }

            # Now, we need to move *.deb to dest.
            move_debfiles($basedir, $output, $sel);
        } else {
            # FIXME: We should try "make deb" here.
            carp "ERROR: Unsupported file type for binary package creation ".
                 "($source_type)";
            return -1;
        }
    } else {
        carp "ERROR: $os->{pkg} is not currently supported";
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
# Return: 0 if no error, else the number of errors during the build process.
sub build_if_needed ($$$$) {
    my ($confp, $pdir, $sel, $target) = @_;
    my ($march, $build_arch, $OHOME, $test, $err);
    $test = 0;

    OSCAR::Logger::oscar_log_subsection ("Building binary packages");

    my $env;
    my %conf = %{$confp};
    if (exists($conf{$sel})) {
#         &srpm_name_ver($pdir,$conf{$sel});

        for my $g (keys(%{$conf{$sel}})) {
            if (create_binary ($pdir, $g, $confp, $sel, $test, $target)) {
                carp "ERROR: Impossible to create the binary ".
                     "($g, $test, $target)";
                $err++;
            }
        }
    }

    if ($err) {
        OSCAR::Logger::oscar_log_subsection ("ERROR: Impossible to create ".
            "some binary packages");
    } else {
        OSCAR::Logger::oscar_log_subsection ("Binary packages created");
    }
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
    my $return_code=0;

    OSCAR::Logger::oscar_log_subsection ("Installing requirements");

    if (!$requires) {
        OSCAR::Logger::oscar_log_subsection ("No requirements to install");
        return 0;
    }
    my $test = 0;
    my @installed_reqs = ();

    my @reqs = split(" ",$requires);
    OSCAR::Logger::oscar_log_subsection ("Requires: ".join(" ",@reqs));

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
            carp "ERROR: Impossible to detect the local distro";
            return -1;
        }
    my $distro_id = "$os->{distro}-$os->{distro_version}-$os->{arch}";
        my $cmd = "/usr/bin/packman install ".join(" ",@install_stack)." --distro $distro_id";
        $cmd .= " --verbose" if $verbose;
        OSCAR::Logger::oscar_log_subsection ("Executing: $cmd");
        if (system($cmd)) {
            print "ERROR: Failed to install requires: ".join(" ",@reqs)."\n";
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
        OSCAR::Logger::oscar_log_subsection ("[INFO] --> Requirements installed");
        return 0;
   }
}


# Input: pdir, where the source code is
#        confp, an array representing the build.cfg file for the software to package.
# Return: 0 if success, -1 else.
sub build_binaries ($$$) {
    my ($pdir, $confp, $output) = @_;
    my $err;

    my @conf_blocks = split_config(@$confp);

    for my $cblock (@conf_blocks) {
        my %conf = %{$cblock};

        # install requires
        if (install_requires($conf{requires})) {
            carp "ERROR: Impossible to install requirements";
            return -1;
        }

        # check and build common-rpms if needed
        $err = build_if_needed(\%conf, $pdir, "common", $output);
        if ($err) {
            carp "ERROR: Impossible to build a binary ($pdir)";
            return -1;
        }

        # check and build dist specific binary packages if needed
        $err = build_if_needed(\%conf, $pdir, "dist", $output);
        if ($err) {
            carp "ERROR: Impossible to build a binary ($pdir)";
            return -1;
        }
    }

    return 0;
}

# Return: 0 if success, -1 else.
sub package_opkg ($$) {
    my ($build_file, $output) = @_;
    if (! -f ($build_file)) {
        carp "ERROR: Invalid path ($build_file)";
        return -1;
    }

    if (! -d $output) {
        carp "ERROR: Output directory does not exist ($output)";
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

    # FIXME: OL: need if $verbose and apropriate message.
    OSCAR::Utils::print_array (@config);

    # main build routine
    if (build_binaries ($pdir, \@config, $output)) {
        carp "ERROR: Impossible to build some binaries";
        return -1;
    }

# 
#     # remove installed requires
#     &remove_installed_reqs;

    return 0;
}

sub available_releases () {
    my $path = "/etc/oscar/oscar-packager";
    my @files = OSCAR::FileUtils::get_files_in_path ("$path");

    die "ERROR: Impossible to scan $path" if (scalar @files == 0);

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

    my $os = OSCAR::OCA::OS_Detect::open();
    if (!defined $os) {
        carp "ERROR: Impossible to detect the binary package format";
        return -1;
    }

    my $cmd = "";
    my $run_script = "";
    if ($os->{pkg} eq "rpm") {
        $run_script = "$dir/build_rpm.sh";
        #$cmd = "mv $dir/*.rpm $output";
    } elsif ($os->{pkg} eq "deb") {
        $run_script = "$dir/build_deb.sh";
    } else {
        carp "ERROR: $os->{pkg} is not currently supported";
        return -1;
    }

    if( -f $run_script ){
        my $pkg_destdir=main::get_pkg_dest();
        $run_script="cd $dir; LC_ALL=C PKGDEST=$pkg_destdir $run_script";
        print "Executing: $run_script\n" if $verbose;
        if (system ($run_script)) {
            carp "ERROR: Impossible to execute $cmd";
            return -1;
        }
    }
    
    my $build_file = "$dir/build.cfg";
    if (! -f "$build_file") {
        OSCAR::Logger::oscar_log_subsection ("No $build_file, no prereqs");
    } else {
        OSCAR::Logger::oscar_log_subsection ("Managing prereqs ($build_file)");
        if (package_opkg ($build_file, $output)) {
            carp "ERROR: Impossible to prepare the prereqs ($dir, $output)";
            return -1;
        }
    }

    return 0;
}


__END__

=head1 Exported functions

=over 4

=item package_opkg

Package a given OPKG. Example: package_opkg ("/var/lib/oscar/package/c3/build.cfg");

=item available_releases

Returns the list of OSCAR releases that can be packaged. Example: my @oscar_releases = available_releases ();

=back

=head1 AUTHORS

=over 4

=item Erich Fotch

=item Geoffroy Vallee, Oak Ridge National Laboratory <valleegr at ornl dot gov>

=back

=cut
