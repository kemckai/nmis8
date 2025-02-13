#!/usr/bin/perl
#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#
#  ALL CODE MODIFICATIONS MUST BE SENT TO CODE@OPMANTEK.COM
#
#  This file is part of Network Management Information System ("NMIS").
#
#  NMIS is free software: you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#
#  NMIS is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with NMIS (most likely in a file named LICENSE).
#  If not, see <http://www.gnu.org/licenses/>
#
#  For further information on NMIS or for a license other than GPL please see
#  www.opmantek.com or email contact@opmantek.com
#
#  User group details:
#  http://support.opmantek.com/users/
#
# *****************************************************************************
use 5.10.1;

# Load the necessary libraries
use FindBin;
use lib "$FindBin::Bin/lib";

use strict;
use DirHandle;
use Data::Dumper;
#! this imports the LOCK_ *constants (eg. LOCK_UN, LOCK_EX)
use Fcntl qw(:DEFAULT :flock);
use File::Copy;
use File::Find;
use File::Basename;
use File::Path;
use Cwd;
use POSIX qw(:sys_wait_h);
use version 0.77;
use Getopt::Std;

my $me = basename($0);

my $defsite = "/usr/local/nmis8";
my $usage = qq!
NMIS Copyright (C) Opmantek Limited (www.opmantek.com)
This program comes with ABSOLUTELY NO WARRANTY;

Usage: $me [-hydl] [-t /some/path|site=/some/path] [listdeps=0/1]

-h:  show this help screen
-d:  produce extra debug output and logs
-l:  No installation, only show (missing) dependencies
-t:  Installation target, default is $defsite
-y:  non-interactive  mode, all questions are pre-answered
     with the default choice\n\n!;

# relax an overly strict umask but for the duration of the installation only
# otherwise dirs and files that are created end up inaccessible for the nmis user...
umask(0022);

my $nmisModules;			# local modules used in our scripts

die $usage if ( $ARGV[0] =~ /^-(\?|h|-help)$/i );
# let's prefer std -X flags, fall back to word=value style
my (%options, %oldstyle);
die $usage if (!getopts("yldt:", \%options));
%oldstyle = getArguements(@ARGV) if (@ARGV);

my $site = $options{t} || $oldstyle{site} || $defsite;
my $listdeps = $options{l} || ($oldstyle{listdeps} =~ /^(1|true|yes)$/i);
my $debug = $options{d} || $oldstyle{debug};
my $noninteractive = $options{y};

die "This installer must be run with root privileges, terminating now!\n"
		if ($> != 0);

system("clear");
my ($installLog, $mustmovelog);
if ( -d $site )
{
	$installLog = "$site/install.log";
}
else
{
	$installLog = "/tmp/install.log";
	$mustmovelog = 1;
}


###************************************************************************###
printBanner("NMIS Installer");
my $hostname = `hostname -f`; chomp $hostname;

# figure out where we install from; current dir, check the dirname of this command's invocation, or give up
my $src = cwd();
$src = Cwd::abs_path(dirname($0)) if (!-f "$src/LICENSE");
die "Cannot determine installation source directory!\n" if (!-f "$src/LICENSE");

die "The installer cannot be run out of the live target directory!
Please unpack the NMIS sources in a different directory (e.g. /tmp)
and restart the installer there!\n\n" if ($src eq $site);

my $nmisversion;
open(G, "./lib/NMIS.pm");
for  my $line (<G>)
{
	if ($line =~ /^\s*(our\s+)?\$VERSION\s*=\s*"(.+)";\s*$/)
	{
		$nmisversion = $2;
		last;
	}
}
close G;
logInstall("Installation of NMIS $nmisversion on host '$hostname' started at ".scalar localtime(time));

# safeguard against local::lib breaking system-wide module installation for cpan'ables

# if PERL5LIB was set, remove all its members from @INC or the module availabilty test will
# look in the wrong places
if (defined $ENV{PERL_LOCAL_LIB_ROOT})
{
	logInstall("clearing local::lib config items");
	for my $dontwantpath (split(/:/,$ENV{PERL5LIB}))
	{
		@INC = grep($_ ne $dontwantpath, @INC); # bit inefficient but good enough
	}
	for my $dontwant (qw(PERL_LOCAL_LIB_ROOT PERL5LIB PERL_MM_OPT PERL_MB_OPT))
	{
		delete $ENV{$dontwant};
	}
}

delete $ENV{"PERL_CPANM_OPT"};

if ($noninteractive)
{
	$ENV{"PERL_MM_USE_DEFAULT"}=1;
}
else
{
	$ENV{"PERL_MM_USE_DEFAULT"}=0;
}

# there are some slight but annoying differences
my ($osflavour,$osmajor,$osminor,$ospatch,$osiscentos);
if (-f "/etc/redhat-release")
{
	$osflavour="redhat";
	logInstall("detected OS flavour RedHat/CentOS");

	open(F, "/etc/redhat-release") or die "cannot read redhat-release: $!\n";
	my $reldata = join('',<F>);
	close(F);

	($osmajor,$osminor,$ospatch) = ($1,$2,$4)
			if ($reldata =~ /(\d+)\.(\d+)(\.(\d+))?/);
	$osiscentos = 1 if ($reldata =~ /CentOS/);
}
elsif (-f "/etc/os-release")
{
	open(F,"/etc/os-release") or die "cannot read os-release: $!\n";
	my $osinfo = join("",<F>);
	close(F);
	if ($osinfo =~ /ID=debian/)
	{
		$osflavour="debian";
		logInstall("detected OS flavour Debian");
	}
	elsif ($osinfo =~ /ID=ubuntu/)
	{
		$osflavour="ubuntu";
		logInstall("detected OS flavour Ubuntu");
	}
	($osmajor,$osminor,$ospatch) = ($1,$3,$5)
			if ($osinfo =~ /VERSION_ID=\"(\d+)(\.(\d+))?(\.(\d+))?\"/);
}
if (!$osflavour)
{
	echolog("Attention: The installer was unable to determine the type of your OS
and won't be able to make certain installation adjustments!

We recommend that you check the NMIS Installation guide at
https://community.opmantek.com/x/Dgh4
for further info.\n\n");
	&input_ok;
}
logInstall("Detected OS $osflavour, Major $osmajor, Minor $osminor, Patch $ospatch");

logInstall("Installation source is $src");

###************************************************************************###
printBanner("Checking Perl version...");

if ($^V < version->parse("5.10.1"))
{
	echolog("The version of Perl installed on your server is lower than the minimum
supported version 5.10.1. Please upgrade to at least Perl 5.10.1");
	exit 1;
}
else {
	echolog("The version of Perl installed on your server is $^V and OK");
}

printBanner("Checking SELinux Status");
my $rawstatus = system("selinuxenabled");
if (WIFEXITED($rawstatus))
{
	if (WEXITSTATUS($rawstatus) == 0)
	{
		my $flavour = `getenforce 2>/dev/null`;
		chomp ($flavour);

		if ($flavour =~ /permissive/i)
		{
			echolog("SELinux is enabled but in permissive mode.");
		}
		else
		{
			echolog("SELinux is enabled!");
			print "\n
The installer has detected that SELinux is enabled on your system
and that it is set to enforce its policy.\n
SELinux needs extensive configuration to work properly.\n
In its default configuration it is known to interfere with NMIS,
and we do therefore recommend that you disable SELinux for NMIS.

See \"man 8 selinux\" for details.

\n";
			if ("CONTINUE" ne input_str("Type CONTINUE to continue regardless of SELinux, or any other key to abort: ",
																	undef, undef))
			{
				echolog("\n\nAborting installation because of SELinux state.");
				exit 1;
			}
		}
	}
	else
	{
		echolog("SELinux is not enabled.");
	}
}
else
{
	echolog("Could not determine SELinux status, exit code was $rawstatus");
}

###************************************************************************###
my $can_use_web;
if ($osflavour)
{
	my @debpackages = (qw(autoconf automake gcc make libcairo2 libcairo2-dev libglib2.0-dev cpanminus
libpango1.0-dev libxml2 libxml2-dev libnet-ssleay-perl
libcrypt-ssleay-perl apache2 fping nmap snmp snmpd snmptrapd libnet-snmp-perl
libcrypt-passwdmd5-perl libjson-xs-perl libnet-dns-perl
libio-socket-ssl-perl libwww-perl libwww-mechanize-perl libnet-smtp-ssl-perl libnet-smtps-perl
libcrypt-unixcrypt-perl libcrypt-rijndael-perl libuuid-tiny-perl libproc-processtable-perl libdigest-sha-perl
libnet-ldap-perl libdbi-perl
libsoap-lite-perl libauthen-simple-radius-perl libauthen-tacacsplus-perl
libauthen-sasl-perl rrdtool librrds-perl libtest-deep-perl dialog libcrypt-des-perl libdigest-hmac-perl libclone-perl
libexcel-writer-xlsx-perl libmojolicious-perl libdatetime-perl
libnet-ip-perl libscalar-list-utils-perl libtest-requires-perl libtest-fatal-perl libtest-number-delta-perl libtext-csv-perl libtext-csv-xs-perl libauthen-pam-perl

));

	my @rhpackages = (qw(perl-core autoconf automake gcc cvs cairo cairo-devel
pango pango-devel glib glib-devel libxml2 libxml2-devel gd gd-devel
libXpm-devel libXpm openssl openssl-devel net-snmp net-snmp-libs
net-snmp-utils net-snmp-perl perl-IO-Socket-SSL perl-Net-SSLeay
perl-JSON-XS httpd fping nmap make groff perl-CPAN perl-App-cpanminus crontabs dejavu*
perl-libwww-perl perl-WWW-Mechanize perl-Net-DNS perl-Digest-SHA
perl-DBI perl-Net-SMTPS perl-Net-SMTP-SSL perl-CGI net-snmp-perl perl-Proc-ProcessTable perl-Authen-SASL
perl-Crypt-PasswdMD5 perl-Crypt-Rijndael perl-Net-SNMP perl-GD rrdtool
rrdtool-perl perl-Test-Deep dialog
perl-Excel-Writer-XLSX perl-Net-IP perl-DateTime
perl-Digest-HMAC perl-Crypt-DES perl-Clone perl-ExtUtils-CBuilder
perl-ExtUtils-ParseXS perl-ExtUtils-MakeMaker perl-Test-Fatal perl-Test-Number-Delta
perl-Test-Requires perl-JSON perl-XML-SAX perl-XML-SAX-Writer perl-Convert-ASN1
perl-Text-CSV perl-Text-CSV_XS perl-Authen-PAM));

	# perl-Time-modules no longer a/v in rh/centos7
	push @rhpackages, ($osflavour eq "redhat" && $osmajor < 7)?
			"perl-Time-modules" : "perl-Time-ParseDate";

	# cgi was removed from core in 5.20
	if (version->parse($^V) >= version->parse("5.19.7"))
	{
		push @debpackages, "libcgi-pm-perl";
		push @rhpackages, "perl-CGI";
	}

	# stretch/9 ships with these packages that jessie/8 didn't
	push @debpackages, (qw(libproc-queue-perl libstatistics-lite-perl libtime-moment-perl libgd-perl ))
			if ($osflavour eq "debian" and $osmajor >= 9);
	# stretch no longer ships with these packages...
	push @debpackages, (qw(libui-dialog-perl libsys-syslog-perl))
			if ($osflavour eq "debian" and $osmajor <= 8);
	# buster/10 ships with these packages...
	push @debpackages, (qw(libtime-parsedate-perl libui-dialog-perl))
			if ($osflavour eq "debian" and $osmajor >= 10);
	# ...but buster no longer ships with those - now virtual
	push @debpackages, (qw(libtime-modules-perl))
			if ($osflavour eq "debian" and $osmajor <= 9);

	# ubuntu 16.04.3 lts does have a different subset
	push @debpackages, (qw(libproc-queue-perl libstatistics-lite-perl libgd-perl libui-dialog-perl))
			if ($osflavour eq "ubuntu" and $osmajor >= 16);
	# ubuntu ships with that one up to and including 18.04lts
	push @debpackages, (qw(libtime-modules-perl)) if ($osflavour eq "ubuntu");

	my $pkgmgr = $osflavour eq "redhat"? "YUM": ($osflavour eq "debian" or $osflavour eq "ubuntu")? "APT": undef;
	my $pkglist = $osflavour eq "redhat"? \@rhpackages : ($osflavour eq "debian" or $osflavour eq "ubuntu")? \@debpackages: undef;

	# first check if internet/web access is available
	printBanner("Checking Web access...");

	# curl is present in most basic redhat install
	# wget is present on debian/ubuntu via priority:important
	# however, ca-certificates may be out of date/incomplete at this time
	my $testres = system("curl --insecure -s -m 10 -o /dev/null https://opmantek.com/robots.txt 2>/dev/null") >> 8;
	$testres = system("wget --no-check-certificate -q -T 10 -O /dev/null https://opmantek.com/robots.txt 2>/dev/null") >> 8
			if ($testres);
	$can_use_web = !$testres;

	if ($can_use_web)
	{
		echolog("Web access is ok.");
	}
	else
	{
		echolog("No Web access available!");
		print "Your system cannot access the web, therefore $pkgmgr will not
be able to download any missing software packages. If any
such missing packages are detected and you don't have
a local source of packages (e.g. an installation DVD) then the
installation won't complete successfully.

We recommend that you check our Wiki article on working around
package installation without Internet access in that case:

https://community.opmantek.com/x/boSG\n\n";
		&input_ok;
	}

	if ($osflavour eq "debian" or $osflavour eq "ubuntu")
	{
		my @unresolved;

		# one or two packages are not a/v in wheezy
		my $osversion = `lsb_release -r`; $osversion =~ s/^.*:\s*//;

		printBanner("Updating package status, please wait...");
		execPrint("apt-get update -qq");

		printBanner("Checking Dependencies...");

		for my $pkg (@debpackages)
		{
			next if ($pkg =~ /^(snmptrapd|libnet-smtps-perl)$/ # in snmpd/not packaged in wheezy
							 and $osflavour eq "debian"
							 and version->parse($osversion) < version->parse("8.0"));
			next if ($pkg eq "snmptrapd"		# included in snmpd before  15.10
							 and $osflavour eq "ubuntu"
							 and version->parse($osversion) < version->parse("15.10"));

			if (`dpkg -l $pkg 2>/dev/null` =~ /^[hi]i\s*$pkg\s*/m)
			{
				echolog("Required package $pkg is already installed.");
			}
			else
			{
				echolog("Required package $pkg is NOT installed!");
				push @unresolved, $pkg;
			}
		}

		if (@unresolved)
		{
			my $packages = join(" ",@unresolved);
			echolog("\n\nSome required packages are missing:
$packages\n
The installer can use $pkgmgr to download and install these packages.\n");

			if (input_yn("Do you want to install these packages with $pkgmgr now?"))
			{
				$ENV{"DEBIAN_FRONTEND"}="noninteractive";

				for my $missing (@unresolved)
				{
					echolog("\nInstalling $missing with apt-get");
					execPrint("apt-get -yq install $missing");
				}
				print "\n\n";			# apt is a bit noisy
			}
			else
			{
				echolog("Required packages not present but installer instructed to NOT install them.");
				print "\nNMIS will not run correctly without the following packages installed:\n
$packages\n
You will have to resolve these
dependencies manually before NMIS can operate properly.\n\nHit <Enter> to continue:\n";
					my $x = <STDIN>;
			}
		}
	}
	elsif ($osflavour eq "redhat")
	{
		my %unresolved;

		if ($can_use_web)
		{
			printBanner("Updating YUM metadata cache...");
			system("yum makecache");
		}

		printBanner("Checking Dependencies...");

		# a few packages are only available via the EPEL repo, others need more magic...
		# check the enabled extra repos
		my %enabled_repos;
		open(F, "yum -C -v repolist enabled|") or die "cannot get repository list from yum: $!\n";
		for my $line (<F>)
		{
			if ($line =~ /^Repo-id\s*:\s*(\S+)/)
			{
				$enabled_repos{$1} = 1;
			}
		}
		close(F);

		# first, disable the rpmforge/repoforge repo, it's unfortunately quite dead...
		if ($enabled_repos{"rpmforge"})
		{
			$enabled_repos{"rpmforge"} = 0;
			if (open(F, "/etc/yum.repos.d/rpmforge.repo"))
			{
				my $repodata = join("",<F>);
				close F;
				$repodata =~  s/enabled\s*=\s*1/enabled=0/g;
				open(F, ">/etc/yum.repos.d/rpmforge.repo") or die "cannot open rpmforge.repo: $!\n";
				print F $repodata;
				close F;
			}
		}

		my @needed;
		for my $pkg (@rhpackages)
		{
			my $installcmd = "yum -y install $pkg";
			my ($ispresent, $present_version, $repo, $reponame, $repourl);

			if (my $rpmstatus = `rpm -qa $pkg 2>/dev/null`)
			{
				$present_version = version->parse($1) if ($rpmstatus =~ /^\S+-(\d+\.\d+(\.\d+)?)/m);
				$ispresent = 1;

				# rrdtool and rrdtool-perl are doubly special - we need a recent enough version
				$ispresent = 0
						if (($pkg eq "rrdtool" or $pkg eq "rrdtool-perl")
								and $present_version < version->parse("1.4.4"));
			}

			if ($ispresent)
			{
				echolog("Required package $pkg is already installed"
								. ($present_version? " (version $present_version)." : "."));
				next;
			}

			# special handling for certain packages: ghettoforge, epel
			# and for centos/rh 6 mainly
			if ($osmajor == 6 and
					($pkg eq "fping" or $pkg eq "rrdtool" or $pkg eq "rrdtool-perl"))
			{
				$installcmd = "yum -y --enablerepo=gf-plus install $pkg";
				$repo="gf";
				$reponame="ghettoforge";
				$repourl = "http://ghettoforge.org/";
			}
			# similar for epel
			elsif ($pkg eq "perl-Net-SNMP" or $pkg eq "glib" or $pkg eq "glib-devel"
						 or $pkg eq "perl-Crypt-Rijndael" or $pkg eq "perl-JSON-XS"
						 or $pkg eq "perl-Net-SMTPS" 
						 or $pkg eq "perl-WWW-Mechanize"
						 or $pkg eq "perl-Proc-ProcessTable")
			{
					$installcmd = "yum -y --enablerepo=epel install $pkg";
					$repo="epel";
					$reponame="EPEL";
					$repourl = "https://fedoraproject.org/wiki/EPEL/";
			}

			echolog("Required package $pkg is NOT installed!");
			$unresolved{$pkg} = { installcmd => $installcmd,
														repo => $repo,
														reponame => $reponame,
														repourl => $repourl };
			push @needed, $pkg;				# would like to install them in order
		}

		if (keys %unresolved)
		{
			my $packages = join(" ",@needed);
			echolog("\n\nSome required packages are missing:
$packages\n
The installer can use $pkgmgr to download and install these packages.\n");

			if (input_yn("Do you want to install these packages with $pkgmgr now?"))
			{
				for my $missing (@needed)
				{
					my ($installcmd, $repo, $reponame, $repourl ) = @{$unresolved{$missing}}{qw(installcmd repo reponame repourl)};

					if ($repo and !$enabled_repos{$repo})
					{
						if (!$can_use_web)
						{
							printBanner("Cannot enable repository $reponame!");
							print "\nThe $reponame repository is required for installing $missing, but
your system does not have web access and thus cannot
download anything from that repository.

You will have to install $missing manually (downloadable
from $repourl).\n";
							&input_ok;
							next;
						}
						else
						{
							enable_custom_repo($repo, $osiscentos, $osmajor);
							$enabled_repos{$repo} = 1;
						}
					}

					echolog("\nInstalling $missing with yum".($repo? " from repository $reponame": ""));
					execPrint($installcmd);

					if ($missing eq "httpd")
					{
						# silly redhat doesn't start services on installation
						execPrint("chkconfig --add $missing");
						execPrint("chkconfig $missing on");
					}
					print "\n\n";			# yum is pretty noisy
				}
			}
			else
			{
				echolog("Required packages not present but installer instructed to NOT install them.");
				print "\nNMIS will not run correctly without the following packages installed:\n
$packages\n
You will have to resolve these
dependencies manually before NMIS can operate properly.\n\n";

				for my $missing (sort keys %unresolved)
				{
					print "The Package $missing can be downloaded from "
							.($unresolved{$missing}->{repourl})."\n"
							if ($unresolved{$missing}->{repourl});
				}

				&input_ok;
			}
		}
	}
}

printBanner("Checking Perl Module Dependencies...");

my ($isok,@missingones) = &check_installed_modules;
if (!$isok)
{
	print "The installer can use CPANM to install the missing Perl packages
that NMIS depends on, if your system has Internet access.\n\n";

	if (!$can_use_web or !input_yn("OK to use CPANM to install missing modules?"))
	{
		echolog("Cannot install missing CPANM modules.");
		print "NMIS will not work properly until the following Perl modules are installed (from CPAN):\n\n".join(" ",@missingones)
				."\n\nWe recommend that you stop the installer now, resolve the dependencies,
and then restart the installer.\n\n";

		if (input_yn("Stop the installer?"))
		{
			die "\nAborting the installation. Please install the missing Perl packages\nwith cpan, then restart the installer.\n";
		}
	}
	else
	{
		# installed cpanm for installing cpan modules
		# as it is far more robust at handling failed tests which hang on cpan installs
		my $cpanm = "cpanm";

		if ($debug)
		{
			my $type_which_cpanm = type_which($cpanm);
			echolog("type_which_cpanm: $type_which_cpanm\n");
		}

		# fix cpanm path if not set
		if (system("type $cpanm >/dev/null") != 0)
		{
			$cpanm = type_which($cpanm);
		}
		if (defined $cpanm)
		{
			echolog("CPANM installation complete, proceeding with module installation using cpanm");
			echolog("cpanm: $cpanm");

			# PERL_CPANM_OPT
			#		If set, adds a set of default options to every cpanm command. These options come first, and so are overridden by command-line options.
			#		I have deliberately not "unset" PERL_CPANM_OPT to allow one to customize cpanm behaviour other than where we have a hardcoded option
			#
			# --prompt option looks really useful to investigate and decide on failed tests, but we must honor $noniteractive
			#
			#		Prompts when a test fails so that you can skip, force install, retry or look in the shell to see what's going wrong.
			#		It also prompts when one of the dependency failed if you want to proceed the installation.
			#		Defaults to false, and you can say --no-prompt to override if it's set in the default options in PERL_CPANM_OPT.
			my $prompt;
			if ($noninteractive)
			{
				$prompt = "";
			}
			else
			{
				$prompt = "--prompt";
			}

			# We pre-install HTTP::Daemon with --notest for this module that often hangs on testing on ubuntu, redhat and centos
			# HTTP::Daemon is a dependency of WWW::Mechanize
			if ( grep( /^WWW::Mechanize$/, @missingones) or grep( /^HTTP::Daemon$/, @missingones) )
			{
				system("cpanm HTTP::Daemon --sudo $prompt --notest 2>&1");	# can't use execprint as cpan is interactive: but is cpanm interactive?
			}
			# We pre-install WWW::Mechanize with --notest for this module that often hangs on testing on ubuntu, redhat and centos
			if ( grep( /^WWW::Mechanize$/, @missingones) )
			{
				system("cpanm WWW::Mechanize --sudo $prompt --notest 2>&1");	# can't use execprint as cpan is interactive: but is cpanm interactive?
			}
			# Net::SNPP fails tests
			if ( grep( /^Net::SNPP$/, @missingones) )
			{
				system("cpanm Net::SNPP --sudo $prompt --notest");	# can't use execprint as cpan is interactive: but is cpanm interactive?
			}
			# default test-timeout is 30 mins: install will return exit code 1 on test timeout
			system("cpanm --sudo $prompt ".join(" ",@missingones)." 2>&1");  # can't use execprint as cpan is interactive but is cpanm interactive?
		}
		else
		{
			echolog("CPANM installation failed");
			# we fallback to cpan code used prior to cpanm
			echolog("Installing modules with CPAN");

			# prime cpan if necessary: non-interactive, follow prereqs,
			if (!-e $ENV{"HOME"}."/.cpan") # might be symlink
			{
				echolog("Performing initial CPAN configuration");
				if ($noninteractive)
				{
					# no inputs, all defaults
					execPrint('cpan');

					# adjust options unsuitable for noninteractive work
					open(F,"|cpan") or die "cannot fork cpan: $!\n";
					print F "o conf prerequisites_policy follow\no conf commit\n";
					close F;
				}
				else
				{
					# there doesn't seem an easy way to prime the cpan shell with args,
					# then let interact with the user via stdin/stdout... and not all versions
					# of cpan seem to start it automatically
					print "\n
If the CPAN configuration doesn't start automatically, then please
enter 'o conf init' on the CPAN prompt.

Should you get prompted to choose Perl Library directories, 'local::lib'
or the like, please choose 'sudo' or 'manual' - NOT 'local::lib'!

To return to the installer when done,
please exit the CPAN\nshell with 'exit'.\n";
					&input_ok;
					system("cpan");
				}
				echolog("CPAN configuration complete, proceeding with module installation");
			}
			system("cpan ".join(" ",@missingones));  # can't use execprint as cpan is interactive
		}
	}
}

if ($listdeps)
{
	echolog("Dependency checks completed, NOT proceeding with installation as requested.\n");
	exit 0;
}

# check that rrdtool is indeed new enough
printBanner("Checking RRDTool Version");
# rrdtool/rrds new enough?
{
	my $rrdisok=0;

	use NMIS::uselib;
	use lib "$NMIS::uselib::rrdtool_lib";

	eval { require RRDs; };
	if (!$@)
	{
		# the rrds version is given in a weird form, eg. 1.4007 meaning 1.4.7.
		# the  version module doesn't quite understand this flavour, expects 1.004007 to mean 1.4.7
		my $foundversion = version->parse("$RRDs::VERSION");
		my $minversion = version->parse("1.4004");
		if ($foundversion >= $minversion)
		{
			echolog("rrdtool/RRDs version $foundversion is sufficient for NMIS.");
			$rrdisok=1;
		}
		else
		{
			echolog("rrdtool/RRDs version $foundversion is NOT sufficient for NMIS, need at least $minversion");
		}
	}
	else
	{
		echolog("No RRDs module found!");
	}

	if (!$rrdisok)
	{
		print "\nNMIS will not work properly without a sufficiently modern rrdtool/RRDs.

We HIGHLY recommend that you stop the installer now, install rrdtool
and the RRDs perl module, and then restart the installer.

You should check the NMIS Installation guide at
https://community.opmantek.com/x/Dgh4
for further info.\n\n";

		if (input_yn("Stop the installer?"))
		{
			die "\nAborting the installation. Please install rrdtool and the RRDs perl module, then restart the installer.\n";
		}
		else
		{
			echolog("\n\nContinuing the installation as requested. NMIS won't work correctly until you install rrdtool and RRDs!\n\n");
			&input_ok;
		}
	}
}

###************************************************************************###
printBanner("Checking Installation Target");
print "The standard NMIS installation target is \"$site\".
To install NMIS into a different directory please answer the question below
with \"no\" and restart the installer with the argument site=<custom_dir>,
e.g. ./install.pl site=/opt/nmis8\n\n";

if (!input_yn("OK to start installation/upgrade to $site?"))
{
	echolog("Exiting installation as directed.\n");
	exit  0;
}

###************************************************************************###
# detect 'conf/Config.nmis' as proof nmis8 installed
if ( -f "$site/conf/Config.nmis" or -l "$site/conf/Config.nmis" )
{
	printBanner("Existing NMIS8 Installation detected");

	print "\nIt seems that you have an existing NMIS installation
in $site. The installer can upgrade the existing installation,
or remove it and install from scratch.\n\n";

	if (input_yn("Do you want to take a backup of your current NMIS install?\n(RRD data is NOT included!)"))
	{
		my $backupFile = getBackupFileName();

		my $apacheconfig = $osflavour eq "redhat"?
				"/etc/httpd/conf.d/nmis.conf" : ($osflavour eq "debian" or $osflavour eq "ubuntu")?
				"/etc/apache2/sites-available/nmis.conf" : undef;

		execPrint("tar -C $site -czf ~/$backupFile ./admin ./bin ./cgi-bin ./conf ./install ./lib ./menu ./mibs ./models /etc/cron.d/nmis /etc/logrotate.d/nmis $apacheconfig");
		echolog("Backup of NMIS install was created in ~/$backupFile\n");
	}

	if (!input_yn("\nDo you want to upgrade the existing installation?
If you say No here, the existing installation will be REMOVED and OVERWRITTEN!\n")
			&& input_yn("\nPlease confirm that you want to REMOVE the existing installation:"))
	{
		rename($site,"$site.unwanted") or die "Cannot rename $site to $site.unwanted: $!\n";
		$installLog = "$site.unwanted/install.log";
		$mustmovelog = 1;
	}
}
else
{
	logInstall("Completely new NMIS8 Installation detected");
}

my $isnewinstall=0;
# detect 'conf/Config.nmis' as proof nmis8 installed
if ( ! -f "$site/conf/Config.nmis" and ! -l "$site/conf/Config.nmis" )
{
	$isnewinstall=1;
}
logInstall("NMIS8 Installation \$isnewinstall=$isnewinstall");

if (!-d $site )
{
	safemkdir($site);
}

# now switch to the install.log in the final location
if ($mustmovelog)
{
	my $newlog = "$site/install.log";
	system("mv $installLog $newlog");
	$installLog = $newlog;
}

if (! $isnewinstall)
{
	# move debug.pl
	my $debug_src="$site/cgi-bin/debug.pl";
	if ( -f $debug_src or -l $debug_src )
	{
		my $debug_tgt="$site/admin/debug.pl";

		echolog("Moving '$debug_src' to '$debug_tgt'");
		safemkdir("$site/admin");
		execPrint("mv -f '$debug_src' '$debug_tgt'");
	}
}

# before copying anything, kill fpingd and lock nmis (fpingd doesn't even start if locked out)
execPrint("$site/bin/fpingd.pl kill=true") if (-x "$site/bin/fpingd.pl");
open(F,">$site/conf/NMIS_IS_LOCKED");
print F "$0 is operating, started at ".(scalar localtime)."\n";
close F;
open(F, ">/tmp/nmis_install_running");
print F $$;
close(F);

printBanner("Copying NMIS files...");
echolog("Copying source files from $src to $site...\n");

my @candidates;
find(sub
		 {
			 my ($name,$dir,$fn) = ($_, $File::Find::dir, $File::Find::name);
			 push @candidates, [$fn] if (-d $fn); # make sure the directories are created!
			 push @candidates, [$dir, $name] if (-f $fn); # source contains no symlinks
		 }, $src);

for (@candidates)
{
	my ($sourcedir,$name) = @$_;
	my $sourcefile = "$sourcedir/$name";

	(my $targetdir = $sourcedir) =~ s!^$src!!;
	$targetdir = $site."/".$targetdir;
	safemkdir($targetdir) if (!-d $targetdir);

	# just make the dir
	if (!defined $name)
	{
		safemkdir($targetdir) if (!-d $targetdir);
	}
	else
	{
		my $targetfile = Cwd::abs_path($targetdir."/".$name);
		safecopy($sourcefile, $targetfile);
	}
}

# catch missing nmis user, regardless of upgrade/new install
if (!getpwnam("nmis"))
{
	if (input_yn("OK to create NMIS user?"))
	{
		# redhat/centos' adduser is non-interactive, debian/ubuntu's wants interaction
		if ($osflavour eq "redhat")
		{
			execPrint("adduser nmis");
		}
		elsif ($osflavour eq "debian" or $osflavour eq "ubuntu")
		{
			execPrint("useradd nmis");
		}
	}
	else
	{
		echolog("Continuing without nmis user.\n");
	}
}

if ($isnewinstall)
{
	printBanner("Installing default config files...");
	safemkdir("$site/conf") if (!-d "$site/conf");
	safemkdir("$site/models") if (!-d "$site/models");

	# -n(oclobber) should not be required as conf site/conf/ and site/models/ should be empty
	# exexprint returns exit code, ie. 0 if ok
	die "copying of default config failed!\n" if (execPrint("cp -an $site/install/* $site/conf/"));
	die "copying of default models failed!\n" if (execPrint("cp -an $site/models-install/* $site/models/"));
	# this test plugin shouldn't be activated automatically
	unlink("$site/conf/plugins/TestPlugin.pm") if (-f "$site/conf/plugins/TestPlugin.pm");
}
else
{
	# if somehow this got installed, lets uninstall it.
	unlink("$site/conf/plugins/TestPlugin.pm") if (-f "$site/conf/plugins/TestPlugin.pm");

	# copy over missing plugins if allowed
	opendir(D,"$site/install/plugins") or warn "cannot open directory install/plugins: $!\n";
	my @candidates = grep(/\.pm$/, readdir(D));
	closedir(D);

	if (@candidates)
	{
		safemkdir("$site/conf/plugins") if (!-d "$site/conf/plugins");
		printBanner("Updating plugins");

		for my $maybe (@candidates)
		{
			next if ($maybe eq "TestPlugin.pm"); # this example plugin shouldn't be auto-activated
			my $docopy = 0;
			if (-e "$site/conf/plugins/$maybe")
			{
				my $havechange = system("diff -q $site/install/plugins/$maybe $site/conf/plugins/$maybe >/dev/null 2>&1") >> 8;
				$docopy = ($havechange and input_yn("OK to replace changed plugin $maybe?"));
			}
			if ($docopy)
			{
				safecopy("$site/install/plugins/$maybe","$site/conf/plugins/$maybe");
			}
		}
	}

	printBanner("Copying new and updated NMIS config files");
	# copy if missing - note: doesn't cover syntactically broken, though
	for my $cff ("License.nmis", "Access.nmis", "Config.nmis", "BusinessServices.nmis", "ServiceStatus.nmis",
							 "Contacts.nmis", "Enterprise.nmis", "Escalations.nmis",
							 "ifTypes.nmis", "Links.nmis", "Locations.nmis", "Logs.nmis",
							 "Customers.nmis", "Events.nmis", "Polling-Policy.nmis",
							 "Model-Policy.nmis", "Modules.nmis", "Nodes.nmis",
							 "Outage.nmis", "Portal.nmis",
							 "PrivMap.nmis", "Services.nmis", "Users.nmis", "users.dat")
	{
		if (-f "$site/install/$cff" && !-e "$site/conf/$cff")
		{
			safecopy("$site/install/$cff","$site/conf/$cff");
		}
	}

	printBanner("Removing outdated/moved config files");
	# script moved to admin
	execPrint("rm -f $site/conf/update_config_defaults.pl $site/install/update_config_defaults.pl");

	###************************************************************************###
	printBanner("Updating the config files with any new options...");

	if (input_yn("OK to update the config files?"))
	{
		# merge changes for new NMIS Config options.
		execPrint("$site/admin/updateconfig.pl $site/install/Config.nmis $site/conf/Config.nmis");
		execPrint("$site/admin/updateconfig.pl $site/install/Access.nmis $site/conf/Access.nmis");

		# update default config options that have been changed:
		execPrint("$site/admin/update_config_defaults.pl $site/conf/Config.nmis");

		execPrint("$site/admin/updateconfig.pl $site/install/Modules.nmis $site/conf/Modules.nmis");

		execPrint("$site/admin/updateconfig.pl $site/install/Events.nmis $site/conf/Events.nmis");

		# patch config changes that affect existing entries, which update_config_defaults
		# doesn't handle
		# which includes enabling uuid and showing the polling_policy
		execPrint("$site/admin/patch_config.pl -b $site/conf/Config.nmis /system/non_stateful_events='Node Configuration Change, Node Configuration Change Detected, Node Reset, NMIS runtime exceeded, Interface ifAdminStatus Changed'  /system/node_summary_field_list,=uuid /system/json_node_fields,=uuid /system/network_viewNode_field_list,=polling_policy");
		echolog("\n");

		echolog("By default this version NMIS demotes nodes that have never
been collected successfully to a single collection attempt once every 24 hours.

If you choose Y below, then the installer will change the configuration
setting demote_faulty_nodes to false, and NMIS will try to collect such nodes
every 5 minutes.");

		if (input_yn("Should NMIS retry totally uncollectable nodes every 5 min?"))
		{
			execPrint("$site/admin/patch_config.pl $site/conf/Config.nmis /system/demote_faulty_nodes=false");
			echolog("\n");
		}

		# ask iff required
		my %escrules = eval { do "$site/conf/Escalations.nmis" } if (-f "$site/conf/Escalations.nmis");
		if (!keys %escrules
				or (ref($escrules{"default_default_default_default__"}) eq "HASH"
						&& $escrules{"default_default_default_default__"}->{Level0}))
		{
			if (input_yn("OK to remove syslog and JSON logging from default event escalation?"))
			{
				execPrint("$site/admin/patch_config.pl -b $site/conf/Escalations.nmis /default_default_default_default__/Level0=''");
				echolog("\n");
			}
		}

		my %newconfig = eval { do "$site/conf/Config.nmis"; } if (-f "$site/conf/Config.nmis");
		if (!keys %newconfig
				or $newconfig{system}->{fastping_timeout} < 5000
				or $newconfig{system}->{ping_timeout} < 5000)
		{
			if (input_yn("OK to set the FastPing/Ping timeouts to the new default of 5000ms?"))
			{
				execPrint("$site/admin/patch_config.pl -b -n $site/conf/Config.nmis /system/fastping_timeout=5000 /system/ping_timeout=5000");
				echolog("\n");
			}
		}

		if ($newconfig{system}->{keep_event_history}
				&& $newconfig{system}->{keep_event_history} ne "false"
				&& input_yn("OK to disable retaining of historic events?"))
		{
			execPrint("$site/admin/patch_config.pl -b $site/conf/Config.nmis /system/keep_event_history=false");
			echolog("\n");
		}

		# offer to setup nmis-omk sso, if it's safe to do so
		# ie: if omk is present, no sso is configured for omk or nmis,
		# and the current cookie flavour is the (pretty unsafe old-style) 'nmis'
		if (-d "/usr/local/omk")
		{
			my %nmisconfig = do "$site/conf/Config.nmis";
			my %omkconfig = do "/usr/local/omk/conf/opCommon.nmis";
			if (keys %nmisconfig
					&& $nmisconfig{authentication}->{auth_cookie_flavour} eq "nmis"
					&& keys %omkconfig
					&& !$omkconfig{authentication}->{auth_sso_domain}
					&& !$nmisconfig{authentication}->{auth_sso_domain}
					&& input_yn("OK to enable authentication cookie sharing (SSO) with Opmantek applications?"))
			{
				my $mustsharethis = $omkconfig{omkd}->{omkd_secrets}->[0];

				printBanner("Enabling NMIS-OMK Single-Sign-On");
				execPrint("$site/admin/patch_config.pl -b $site/conf/Config.nmis /authentication/auth_web_key=$mustsharethis /authentication/auth_cookie_flavour=omk");
			}
		}

		# move config/cache files to new locations where necessary
		if (-f "$site/conf/WindowState.nmis")
		{
			printBanner("Moving old WindowState file to new location");
			execPrint("mv $site/conf/WindowState.nmis $site/var/nmis-windowstate.nmis");
		}

		# disable the uuid plugin, which this version doesn't need
		my $obsolete = "$site/conf/plugins/UUIDPlugin.pm";
		if (-f $obsolete)
		{
			echolog("Disabling obsolete UUID Plugin");
			rename($obsolete, "$obsolete.disabled");
		}

		# handle table files, automatically where possible
		printBanner("Performing Table Upgrades");

		my @upgradables = `$site/admin/upgrade_tables.pl -o $site/install $site/conf 2>&1`;
		my $ucheck = $? >> 8;
		my @problematic = `$site/admin/upgrade_tables.pl -p $site/install $site/conf 2>&1`;
		logInstall("table upgrade check:\n".join("", @upgradables, @problematic));

		# first mention the problematic files
		if ($ucheck & 1)
		{
			printBanner("Non-upgradeable Table files detected");
			print "\nThe installer has detected the following table files that require
manual updating:\n\n" .join("", @problematic) ."\n";
			&input_ok;
		}
		else
		{
			echolog("No table files in need of manual updating detected.");
		}

		if ($ucheck & 2)
		{
			printBanner("Auto-upgradeable table files detected");

			print "The installer has detected the following auto-upgradeable table files:\n\n"
					.join("", @upgradables)."\n";

			if (input_yn("Do you want to upgrade these tables now?"))
			{
				execPrint("$site/admin/upgrade_tables.pl -u $site/install $site/conf 2>&1");
			}
			else
			{
				echolog("Not upgrading tables, as directed.");

				print "\nWe recommend that you use the table upgrade tool to keep your tables up
to date. You find this tool in $site/admin/upgrade_tables.pl.\n";
				&input_ok;
			}
		}
		else
		{
			echolog("No upgradeable table files detected.");
		}

		# handle the model files, automatically where possible
		printBanner("Performing Model Upgrades");

		@upgradables = `$site/admin/upgrade_models.pl -o -n Common-database $site/models-install $site/models 2>&1`;
		$ucheck = $? >> 8;
		@problematic = `$site/admin/upgrade_models.pl -p -n Common-database $site/models-install $site/models 2>&1`;
		logInstall("model upgrade check:\n".join("", @upgradables, @problematic));

		# first mention the problematic models
		if ($ucheck & 1)
		{
			printBanner("Non-upgradeable model files detected");
			print "\nThe installer has detected the following model files that require
manual updating:\n\n" .join("", @problematic) ."\nYou should check the NMIS Wiki for instructions on manual
model upgrades: https://community.opmantek.com/x/-wd4\n";
			&input_ok;
		}
		else
		{
			echolog("No model files in need of manual updating detected.");
		}

		if ($ucheck & 2)
		{
			printBanner("Auto-upgradeable model files detected");

			print "The installer has detected the following auto-upgradeable model files:\n\n"
					.join("", @upgradables)."\n";

			if (input_yn("Do you want to perform this model upgrade now?"))
			{
				execPrint("$site/admin/upgrade_models.pl -u -n Common-database $site/models-install $site/models 2>&1");
			}
			else
			{
				echolog("Not upgrading models, as directed.");

				print "\nWe recommend that you use the model upgrade tool to keep your models up
to date. You find this tool in $site/admin/upgrade_models.pl
and the NMIS Wiki has extra information about it at
https://community.opmantek.com/x/-wd4\n";
				&input_ok;
			}
		}
		else
		{
			echolog("No upgradeable model files detected.");
		}

		printBanner("Checking JSON Migration");

		my $havelegacy = execLog("$site/admin/convert_nmis_db.pl simulate=true 2>&1");
		if ($havelegacy)
		{
			print "The installer has detected that your NMIS installation is still using
legacy '.nmis' database files. We recommend that you use the
db conversion tool to migrate your NMIS to JSON.\n\n";

			if (input_yn("Do you want to perform the JSON migration now?"))
			{
				execPrint("$site/admin/convert_nmis_db.pl simulate=false info=1");
			}
			else
			{
				echolog("Not upgrading to JSON files, as directed.");

				print "\nWe recommend that you use the db conversion tool to
switch to JSON. You can find this tool in $site/admin/convert_nmis_db.pl.\n";
				&input_ok;
			}
		}
		else
		{
			echolog("JSON migration not necessary.");
		}

		printBanner("Performing RRD Tuning");
		print "Please be patient, this step can take a while...\n";

		# these four lots of output, so capture and log w/o display

		# that plugin normally does its own confirmation prompting, which cannot work with execPrint
		execLog("$site/admin/install_stats_update.pl nike=true");

		# Updating the mib2ip RRD Type
		execLog("$site/admin/rrd_tune_mib2ip.pl run=true change=true");

		# Updating the TopChanges RRD Type
		execLog("$site/admin/rrd_tune_topo.pl run=true change=true");

		# Updating the TopChanges RRD Type
		execLog("$site/admin/rrd_tune_responsetime.pl run=true change=true");

		execLog("$site/admin/rrd_tune_cisco.pl run=true change=true");

		print "RRD Tuning complete.\n";
	}
	else
	{
		echolog("Continuing without configuration updates as directed.
Please note that you will likely have to perform various configuration updates manually
to ensure NMIS performs correctly.");
		&input_ok;
	}
}

# check that the wmic we've shipped actually works on this platform
my $version = `$site/bin/wmic -V 2>&1`;
my $exit = $?;
if ($exit)
{
	printBanner("Precompiled WMIC failed to run!");
	logInstall("Output of wmic test was: $version");

	print qq|NMIS ships with a precompiled WMI client ($site/bin/wmic),
but for some reason or another the program failed to execute on
your system. This may be caused by shared library incompatibilities,
and the install.log may contain further clues as to what went wrong.

If you want NMIS to collect data from WMI-based nodes you will
have to download wmic from http://dl-nmis.opmantek.com/wmic-omk.tgz,
then compile and install it by hand. The Opmantek Wiki at
https://community.opmantek.com/x/VQJFAQ has more information
on this procedure.

If you do not plan to use WMI-based models you can safely ignore
this issue.\n\n|;
	&input_ok;
}
else
{
	printBanner("Checked precompiled WMIC");
	echolog("Precompiled WMIC ran ok, reported version: $version");
}

###************************************************************************###
printBanner("Cache some fonts...");
execPrint("fc-cache -f -v");

# fix the 8.5.12G common-database gotcha first
if (open(F, "$site/models/Common-database.nmis"))
{
	my @current = <F>;
	close F;
	if (2 == grep(/'ospfNbr'/, @current))
	{
		echolog("Fixing duplicate Common-database entries for ospfNbr");
		# don't want any quoting issues which execPrint or execLog would introduce
		system("$site/admin/patch_config.pl","-b",
					 "$site/models/Common-database.nmis",
					 '/database/type/ospfNbr=/nodes/$node/health/ospfNbr-$index.rrd');
	}
}

# check if the common-databases differ, and if so offer to run migrate_rrd_locations.pl
if (!$isnewinstall)
{
	printBanner("Checking Common-database file for updates");

	# two cases: something new -> updateconfig.pl to fill that in
	# then if there are an issues with actual actual differences, full migration tool run
	my $diffs = `$site/admin/diffconfigs.pl $site/models/Common-database.nmis $site/models-install/Common-database.nmis 2>/dev/null`;
	my $res = $? >> 8;

	if (!$res)
	{
		echolog("No differences between current and new Common-database.nmis found.");
		print "\n\n";
	}
	elsif ($diffs =~ m!^-\s+<NOT PRESENT!m)
	{
		echolog("Found new entries, adding them.");
		execPrint("$site/admin/updateconfig.pl $site/models-install/Common-database.nmis $site/models/Common-database.nmis");
		print "\n\n";
	}

	if ($diffs =~ m!^-\s+/nodes!m) # ie. present but different
	{
		printBanner("RRD Database Migration Required");
		echolog("The installer has detected structural differences between your current
Common-database and the shipped one. These changes can be merged using
the rrd migration script that comes with NMIS.

If you choose Y below, the installer will use admin/migrate_rrd_locations.pl
to move all existing RRD files into the appropriate new locations and merge
the Common-database entries.  This is highly recommended!

If you choose N, then NMIS will continue using the RRD locations specified
in your current Common-database configuration file.\n\n");

		if (input_yn("OK to run rrd migration script?"))
		{
			echolog("Running RRD migration script in test mode first...");
			my $error = execPrint("$site/admin/migrate_rrd_locations.pl newlayout=$site/models-install/Common-database.nmis simulate=true");
			if ($error)
			{
				echolog("Error: RRD migration script detected problems!
The RRD migration script could not complete its test run successfully.
The RRD migration will therefore NOT be performed.

Please check the installation log and diagnostic output for details.\n");
				&input_ok;
			}
			else
			{
				echolog("Performing the actual RRD migration operation...\n");
				my $error = execPrint("$site/admin/migrate_rrd_locations.pl newlayout=$site/models-install/Common-database.nmis leavelocked=true");
				if ($error)
				{
					echolog("Error: RRD migration failed! Please use the rollback script
listed above to revert to the original status!\n");
					&input_ok;
				}
				else
				{
					echolog("RRD migration completed successfully.");
				}
			}
		}
		else
		{
			echolog("Continuing without RRD migration as directed.
You can perform this step manually later, by
running $site/admin/migrate_rrd_locations.pl. This script also has a
simulation mode where it only shows what it WOULD do without making any
changes.

It is highly recommended that you perform the RRD migration.");
			&input_ok;
		}
	}
}

# pidfiles etc. need that dir
safemkdir("$site/var") if (!-d "$site/var");

echolog("Ensuring correct file permissions...");
execPrint("$site/admin/fixperms.pl");

# all files are there; let nmis run
unlink("$site/conf/NMIS_IS_LOCKED");
unlink("$site/var/nmis_system/selftest.json");
unlink("/tmp/nmis_install_running");

# daemon restarting should only be done after nmis is unlocked
printBanner("Restart the fping daemon...");
execPrint("$site/bin/fpingd.pl restart=true");

if ( -x "$site/bin/opslad.pl" ) {
	printBanner("Restarting the opSLA Daemon...");
	execPrint("$site/bin/opslad.pl"); # starts a new one and kills any existing ones
}


###************************************************************************###
printBanner("Checking configuration and fixing file permissions (takes a few minutes) ...");
execPrint("$site/bin/nmis.pl type=config info=true");

printBanner("Integration with Apache");
# determine apache version
my $prog = $osflavour eq "redhat"? "httpd" : "apache2";
my $versioninfo = `$prog -v 2>/dev/null`;
$versioninfo =~ s/^.*Apache\/(\d+\.\d+\.\d+).*$/$1/s;
my $istwofour = ($versioninfo =~ /^2\.4\./);

if (!$versioninfo)
{
	echolog("No Apache found!");
	print "
It seems that you don't have Apache 2.x installed, so the installer
can't configure Apache for NMIS.

The NMIS GUI consists of a number of CGI scripts, which need to be
run by a web server. You will need to integrate NMIS with your particular
web server manually.

Please use the output of 'nmis.pl type=apache' and check the
NMIS Installation guide at
https://community.opmantek.com/x/Dgh4
for further info.\n";
	&input_ok;
}
else
{
	echolog("Found Apache version $versioninfo");

	# older vms ship 00nmis.conf, which definitely needs to be replaced
	my $oldvmconfig = "/etc/httpd/conf.d/00nmis.conf";
	unlink($oldvmconfig) if (-e $oldvmconfig);

	my $apacheconf = "nmis.conf";
	my $res = system("$site/bin/nmis.pl type="
									 .($istwofour?"apache24":"apache")." > /tmp/$apacheconf");
	my $finaltarget = $osflavour eq "redhat"?
			"/etc/httpd/conf.d/$apacheconf" :
			($osflavour eq "debian" or $osflavour eq "ubuntu")? "/etc/apache2/sites-available/$apacheconf" : undef;

	my $copyneeded = (!-f $finaltarget);
	my $copyok = ($copyneeded && input_yn("Ok to install Apache config file to $finaltarget?"));

	if (-f $finaltarget)
	{
		# diff exits 0 if no changes, 1 otherwise	if (-f $finaltarget)
		my $isdifferent = system("diff", "-q", $finaltarget, "/tmp/$apacheconf") >> 8;
		$copyneeded = $isdifferent;
		if ($isdifferent)
		{
			echolog("Existing Apache config is different from shipped config.");
			$copyok = input_yn("Ok to update Apache config file at $finaltarget?");
		}
		else
		{
			echolog("Existing Apache config is uptodate.");
		}
	}

	if ($copyneeded && $copyok)
	{
		execPrint("mv /tmp/$apacheconf $finaltarget");
		execPrint("ln -s $finaltarget /etc/apache2/sites-enabled/")
				if (-d "/etc/apache2/sites-enabled" && !-l "/etc/apache2/sites-enabled/$apacheconf");

		# meh. rh/centos doesn't have a2enmod
		if ($istwofour && $osflavour ne "redhat")
		{
			execPrint("a2enmod cgi");
		}

		if ($osflavour eq "redhat")
		{
			execPrint("usermod -G nmis apache");
			execPrint("service httpd restart");
		}
		elsif ($osflavour eq "debian" or $osflavour eq "ubuntu")
		{
			execPrint("adduser www-data nmis");
			execPrint("service apache2 restart");
		}
	}
	elsif ($copyneeded)						# ie rejected
	{
		echolog("Continuing without Apache configuration update.");
		print "You will need to integrate NMIS with your
web server manually.

Please use the output of 'nmis.pl type=apache' (or type=apache24) and
check the NMIS Installation guide at
https://community.opmantek.com/x/Dgh4
for further info.\n";
		&input_ok;
	}
}

# logrotate 3.8.X wants different rotation config options...
printBanner("NMIS Log Rotation Setup");
my $lrver = `logrotate -v 2>&1`;
if ($lrver =~ /^logrotate (\d+\.\d+\.\d+)/m)
{
	my $version = version->parse("$1");
	echolog("Found logrotate version $version");
	my $lrfile =  "$site/install/" . ($version >= version->parse("3.8.0")? "logrotate.380.conf" : "logrotate.conf");
	my $lrtarget = "/etc/logrotate.d/nmis";

	my $havechange = system("diff -q $lrfile $lrtarget >/dev/null 2>&1") >> 8;
	if (!-f $lrtarget or $havechange)
	{
		if (input_yn("OK to install updated log rotation configuration file\n\t$lrfile in /etc/logrotate.d?"))
		{
			safecopy($lrfile,$lrtarget);
			# recent versions of logrotate reject all files
			# with perms other than 0644 or 0444
			chmod(0644,$lrtarget);
		}
		else
		{
			echolog("Not installing updated $lrfile as requested.");
		}
	}
	else
	{
		echolog("Log rotation file $lrtarget present and same as default");
	}
}
else
{
	print "Cannot determine logrotate's version!\n
The installer could not determine the version of your \"logrotate\" tool,
and you will have to configure log rotation manually. There are two default
log rotation configuration files in $site/install
that you should use as the basis for your setup.\n";
	&input_ok;
}

printBanner("NMIS Cron Setup");

safemkdir("$site/install/cron.d") if (!-d "$site/install/cron.d");
my $systemcronfile = "/etc/cron.d/nmis";
my $newcronfile = "$site/install/cron.d/nmis";
my $showreminder = 1;

echolog("Creating default Cron schedule with nmis.pl type=crontab");
my $res = system("$site/bin/nmis.pl type=crontab system=true >$newcronfile");
if ($res >> 8)
{
	echolog("Warning: default Cron schedule generation failed!");
}
else
{
	my $cronisdifferent = 1;							# not existent yet? that's a difference for sure
	if (-f $newcronfile && -f $systemcronfile)
	{
		$cronisdifferent = system("diff","-q", $systemcronfile, $newcronfile) >> 8;
		echolog("\nExisting NMIS Cron schedule is different from default.") if ($cronisdifferent);
	}
	else
	{
		echolog("\nNo NMIS Cron schedule exists on the system.");
	}

	if (!$cronisdifferent)
	{
		echolog("\nExisting NMIS Cron schedule is up to date.");
		$showreminder = 0;
	}
	else
	{

		print "NMIS relies on Cron to schedule its periodic execution,
and provides an example/default Cron schedule.

The installer can install this default schedule in /etc/cron.d/nmis,
which immediately activates it.

(If you already have old NMIS entries in your root user's crontab,
then the installer will comment out all NMIS entries in
that crontab.)

From 8.6.0 onwards the default Cron schedule uses the nmis_maxthreads
configuration setting (which defaults to 10 parallel processes).\n\n";

		if (input_yn("Do you want the default NMIS Cron schedule\nto be installed in $systemcronfile?"))
		{
			my $res = File::Copy::cp($newcronfile, $systemcronfile);
			if (!$res)
			{
				echolog("Error: writing to $systemcronfile failed: $!");
			}
			else
			{
				$showreminder = 0;
				print "\nA new default cron was created in /etc/cron.d/nmis,
but feel free to adjust it.\n\n";

				my $oldcronfixedup;
				# now clean up the old per-user cron, if there is one!
				echolog("Cleaning up old per-user crontab");
				my $res = system("crontab -l > $site/conf/crontab.root");
				if (0 == $res>>8)
				{
					echolog("Old crontab was saved in $site/conf/crontab.root");

					open (F, "$site/conf/crontab.root") or die "cannot read crontab.root: $!\n";
					my @crondata = <F>;
					close F;
					for my $line (@crondata)
					{
						$line = "# NMIS8 Cron Config is now in /etc/cron.d/nmis\n" if ($line =~ /^#\s*NMIS8 Config/);
						$line = "#disabled! ".$line if ($line =~ m!(nmis8?/bin|nmis8?/conf|nmis8?/admin)!);
					}
					open (G, "|crontab -") or die "cannot fork to update crontab: $!\n";
					print G @crondata;
					close G;
					echolog("Cleaned-up crontab was installed.");
					$oldcronfixedup = 1;
				}

				if ($oldcronfixedup)
				{
					print "Any NMIS entries in root's existing crontab were commented out,
and a backup of the crontab was saved in $site/conf/crontab.root.\n\n";
				}

				&input_ok;
				logInstall("New system crontab was installed in /etc/cron.d/nmis");
			}
		}
	}
}

if ($showreminder)
{
	print "\n\nNMIS will require some scheduling setup to work correctly.\n
An example default Cron schedule is available
in $newcronfile, and you can use
\"$site/bin/nmis.pl type=crontab system=true >/tmp/somefile\"
to regenerate that default.\n";
	&input_ok;
}

###************************************************************************###
printBanner("NMIS State ".($isnewinstall? "Initialisation":"Update"));

# now offer to run an (initial) update to get nmis' state initialised
# and/or updated
if ( !$noninteractive && input_yn("NMIS Update: This may take up to 30 seconds\n(or a very long time with MANY nodes)...\n
Ok to run an NMIS type=update action?"))
{
	print "Update running, please be patient...\n";
	execPrint("$site/bin/nmis.pl type=update force=true mthread=true");
}
else
{
	print "Continuing without the update run as directed.\n\n
It's highly recommended to run nmis.pl type=update once initially
and after every NMIS upgrade - you should do this manually.\n";
	&input_ok;

	logInstall("continuing without the update run.\nIt's highly recommended to run nmis.pl type=update once initially and after every NMIS upgrade - you should do this manually.");
}

if (-d "$site.unwanted" && input_yn("OK to remove temporary/backup files?"))
{
	system('rm','-rf',"$site.unwanted");
}

###************************************************************************###
printBanner("Installation Complete. NMIS Should be Ready to Poll!");
print "You should now be able to access NMIS at http://<yourserver name or ip>/nmis8/\n
Based on your hostname config, this would be\n\thttp://$hostname/nmis8/\n\n";
logInstall("Installation finished at ".scalar localtime);

exit 0;

# this is called for every file found
sub getModules {

	my $file = $File::Find::name;		# full path here

	return if ! -r $file;
	return unless $file =~ /\.pl|\.pm$/;
	parsefile( $file );
}

# this could be used again to find all module dependancies - TBD
sub parsefile {
	my $f = shift;

	open my $fh, '<', $f or print "couldn't open $f\n" && return;

	while (my $line = <$fh>) {
		chomp $line;
		next if (!$line or $line =~ m/^\s*#/);

		# test for module use 'xxx' or 'xxx::yyy' or 'xxx::yyy::zzz'
		if (
			$line =~ m/^(use|require)\s+(\w+::\w+::\w+|\w+::\w+|\w+)(\s+([0-9\.]+))?/
			or $line =~ m/(use|require)\s+(\w+::\w+::\w+|\w+::\w+)(\s+([0-9\.]+))?/
			or $line =~ m/(use|require)\s+(\w+)(\s+([0-9\.]+))?;/
		)
		{
			my ($mod, $minversion) = ($2,$4);
			print "PARSE $f: '$line' => module $mod, minversion $minversion\n" if $debug;

			if ( defined $mod and $mod ne '' and $mod !~ /^\d+/ )
			{
				$nmisModules->{$mod}{file} = 'MODULE NOT FOUND';					# set all as 'MODULE NOT FOUND' here, will check installation status of '$mod' next
				$nmisModules->{$mod}{type} = $1;
				$nmisModules->{$mod}{minversion} = $minversion if (defined $minversion);

				if (not grep {$_ eq $f} @{$nmisModules->{$mod}{by}})
				{
					push(@{$nmisModules->{$mod}{by}},$f);
				}
			}
		}
	}	#next line of script
	close $fh;
}


# returns (1) if no critical modules missing, (0,critical modules) otherwise
sub check_installed_modules
{
	printBanner("Checking for required Perl modules");
	print <<EOF;
This will check for installed Perl modules, first by parsing the
source code to build a list of used modules. Then by checking that
the module exists in the src code or is found in the perl standard
\@INC directory list: @INC

EOF

	my $libPath = "$src/lib";

	my $mod;

	# Check that all the local libaries required by NMIS8, are available to us.
	# when a module is found, parse it for its own reqired modules, so we build a complete install list
	# the nmis base is assumed to be one dir above us, as we should be run from <nmisbasedir>/install folder

	# loop over the check and install script

	find(\&getModules, "$src");

	# add two semi-optional modules, third (digest::md5) is in core
	$nmisModules->{"Crypt::DES"} = { file => "MODULE NOT FOUND", type => "use", by => "lib/snmp.pm" };
	$nmisModules->{"Digest::HMAC"} = { file => "MODULE NOT FOUND", type => "use", by => "lib/snmp.pm" };

	# most of these are critical for getting mojolicious installed, as centos 6
	# has a much too old perl. many of these modules are in core since 5.19 or thereabouts

	$nmisModules->{"IO::Socket::IP"} = { file => "MODULE NOT FOUND", type  => "use",
																			 by => "lib/Auth.pm", minversion => "0.37", priority => 99 };
	# io socket ip needs at least this version of socket...
	$nmisModules->{"Socket"} = { file => "MODULE NOT FOUND", type  => "use",
															 by => "lib/Auth.pm", minversion => "1.97",
															 priority => 99 };
	# and socket needs at least this version of extutils constant to build
	$nmisModules->{"ExtUtils::Constant"} = { file => "MODULE NOT FOUND", type  => "use",
																					 by => "lib/Auth.pm", minversion => "0.23",
																					 priority => 100 };
	# and mojolicious needs all these
	$nmisModules->{"JSON::PP"} = { file => "MODULE NOT FOUND", type  => "use",
																 by => "lib/Auth.pm", priority => 99 };
	$nmisModules->{"Time::Local"} = { file => "MODULE NOT FOUND", type  => "use",
																		by => "lib/Auth.pm", minversion => "1.2", priority => 99 };
	# and time::local needs at least this version of test::More
	$nmisModules->{"Test::More"} = { file => "MODULE NOT FOUND", type  => "use",
																	 by => "lib/Auth.pm", minversion => "0.96", priority => 100 };

	# and time::moment doesn't install cleanly if extutils::parsexs isn't fully installed first
	$nmisModules->{"ExtUtils::ParseXS"} = { file => "MODULE NOT FOUND", type  => "use",
																		 by => "lib/Auth.pm", minversion => "3.18",
																		 priority => 100 };
	# Used by security
	$nmisModules->{"CGI::Session"} = { file => "MODULE NOT FOUND", type  => "use",
																		 by => "lib/Auth.pm", minversion => "4.48",
																		 priority => 100 };

	# now determine if installed or not.
	# sort by the required cpan sequencing (no priority is last)
	foreach my $mod (keys %$nmisModules)
	{
		my $mFile = $mod . '.pm';
		# check modules that are multivalued, such as 'xx::yyy'	and replace :: with directory '/'
		$mFile =~ s/::/\//g;
		# test for local include first
		if ( -e "$libPath/$mFile" ) {
			$nmisModules->{$mod}{file} = "$libPath/$mFile";
			$nmisModules->{$mod}{version} = &moduleVersion("$libPath/$mFile", $mod);
		}
		else {
			# Now look in @INC for module path and name
			# and record the newest one
			foreach my $path( @INC ) {
				if ( -e "$path/$mFile" )
				{
					my $thisversion = moduleVersion("$path/$mFile", $mod);
					if (!$nmisModules->{$mod}{version}
							or !$thisversion
							or version->parse($thisversion) >= version->parse($nmisModules->{$mod}{version}))
					{
						$nmisModules->{$mod}{file} = "$path/$mFile";
						$nmisModules->{$mod}{version} = $thisversion;
					}
				}
			}
		}
	}
	# returns status, list of critical missing
	my ($status, @missing) = &listModules;
	return ($status, @missing);
}


# get the module version
# args: actual file, and module name
# this is non-optimal, and fails on a few modules (e.g. Encode)
sub moduleVersion
{
	my ($mFile, $modname) = @_;
	open FH,"<$mFile" or return 'FileNotFound';
	while (<FH>)
	{
		if (/^\s*((our|my)\s+\$|\$(\w+::)*)VERSION\s*=\s*['"]?\s*[vV]?([0-9\._]+)\s*['"]?s*;/)
		{
			close FH;
			return $4;
		}
	}
	close FH;
	# present but didn't match? ask the module then...
	eval { no warnings; require $mFile; };
	return undef if ($@);

	my $ver = eval { $modname->VERSION };
	return $ver;
}

# returns (1) if no critical modules missing, (0,critical) otherwise
# note that they're returned in order of cpan sequencing priority
sub listModules
{
  my (@missing, @critmissing);
  my %noncritical = ( "Authen::TacacsPlus"=>1, "Authen::Simple::RADIUS"=>1,
											"SNMP_util"=>1, "SNMP_Session"=>1,
											"SOAP::Lite" => 1, "UI::Dialog" => 1, );

  logInstall("Module status follows:\nName - Path - Current Version - Minimum Version\n");
	# sort by install prio, or file
	foreach my $k ( sort { $nmisModules->{$b}->{priority} <=> $nmisModules->{$a}->{priority}
												 or $nmisModules->{$a}{file} cmp $nmisModules->{$b}{file} } keys %$nmisModules)
	{
    logInstall(join("\t", $k, $nmisModules->{$k}->{file},
										$nmisModules->{$k}->{version}||"N/A", $nmisModules->{$k}->{minversion}||"N/A"));
		# report as missing: if not present, or version below required minimum
    push @missing, $k if 	($nmisModules->{$k}->{file} eq "MODULE NOT FOUND"
													 or (defined $nmisModules->{$k}->{minversion}
															 and version->parse($nmisModules->{$k}->{version}) < version->parse($nmisModules->{$k}->{minversion})));
	}

	if (@missing)
	{
		@critmissing = grep( !$noncritical{$_}, @missing);
		my @optionals = grep ($noncritical{$_}, @missing);

		if (@optionals)
		{
			printBanner("Some Optional Perl Modules are missing (or too old)");
			print qq|The following optional modules are missing or too old:\n| .join(" ", @optionals)
					.qq|\n\nNote: The modules Authen::TacacsPlus and Authen::Simple::RADIUS
are optional components for the NMIS AAA system.

The modules SNMP_util and SNMP_Session are also optional (needed only for
the ipsla subsystem) and can be installed either with
'yum install perl-SNMP_Session' or 'apt-get install libsnmp-session-perl'.\n\n|;
		}

		if (@critmissing)
		{
			printBanner("Some Important Perl Modules are missing (or too old)!");
			print qq|The following Perl modules are missing or too old and need
to be installed (or upgraded) before NMIS will work fully:\n\n| . join(" ", @critmissing)."\n\n";

			logInstall("Missing important modules: ".join(" ", @critmissing));
		}

		print qq|These modules can be installed with CPAN:

  perl -MCPAN -e shell
    install [module name]

  or more conveniently by running
   cpan [module name] [module name...]\n\n|;
	}

	my $resultcode = @critmissing? 0 : 1;
	return ($resultcode, @critmissing);
}


# prints prompt, waits for confirmation
sub input_ok
{
	print "\nHit <Enter> to continue:\n";
	my $x = <STDIN> if (!$noninteractive);
}

# print question, return true if y (or in unattended mode). default is yes.
sub input_yn
{
	my ($query) = @_;

	while (1)
	{
		print $query;
		if ($noninteractive)
		{
			print " (auto-default YES)\n\n";
			return 1;
		}
		else
		{
			print "\nType 'y' or <Enter> to accept, or 'n' to decline: ";
			my $input = <STDIN>;
			chomp $input;
			logInstall("User input for \"$query\": \"$input\"");

			if ($input !~ /^\s*[yn]?\s*$/i)
			{
				print "Invalid input \"$input\"\n\n";
				next;
			}

			return ($input =~ /^\s*y?\s*$/i)? 1:0;
		}
	}
}

# print question, return answer (or undef in unattended mode)
# args: prompt, default (default none), confirmation (default false)
# returns response string
sub input_str
{
	my ($query, $default, $wantconfirmation) = @_;

	print $default? "$query [default: $default]" : $query;
	if ($noninteractive)
	{
		print " (auto-default)\n\n";
		return $default;
	}
	else
	{
		while (1)
		{
			my $result;

			print "\nEnter your response or hit <Enter> to accept default: ";
			my $input = <STDIN>;
			chomp $input;
			logInstall("User input for \"$query\": \"$input\"");

			$result = $input ne ''? $input: $default;

			if ($wantconfirmation)
			{
				print "You entered '$input' -  Is this correct ? <Enter> to accept, or any other key to go back: ";
				$input = <STDIN>;
				chomp $input;
				return $result if ($input eq '');
			}
			else
			{
				return $result;
			}
		}
	}
}

sub getBackupFileName {
	my $time = shift;
	if ( $time == 0 ) { $time = time; }
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)=localtime($time);
	if ($year > 70) { $year=$year+1900; }
	        else { $year=$year+2000; }
	if ($hour<10) {$hour = "0$hour";}
	if ($min<10) {$min = "0$min";}
	if ($sec<10) {$sec = "0$sec";}
	# Do some sums to calculate the time date etc 2 days ago
	$wday=('Sun','Mon','Tue','Wed','Thu','Fri','Sat')[$wday];
	$mon=('Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec')[$mon];
	return "nmis8-backup-$year-$mon-$mday-$hour$min.tgz";
}

sub printBanner {
	my $string = shift;

	print <<EOF;

++++++++++++++++++++++++++++++++++++++++++++++++++++++
$string
++++++++++++++++++++++++++++++++++++++++++++++++++++++

EOF

	logInstall("\n\n###+++\n$string\n###+++\n");
}


# run external program/command via a shell
# external command cannot not prompt or read stdin!
# returns the command's exit code or -1 for signal/didn't start/non-standard termination
sub execPrint {
	my $exec = shift;
	my $out = `$exec </dev/null 2>&1`;
	my $rawstatus = $?;
	my $res = WIFEXITED($rawstatus)? WEXITSTATUS($rawstatus): -1;
	print $out;
	logInstall("\n\n###+++\nEXEC: $exec\n");
	logInstall($out);
	logInstall("###". ($res? " Exit Code: $res ":''). "+++\n\n");
	return $res;
}

# like execPrint BUT output is only logged, not printed
sub execLog {
	my $exec = shift;
	my $out = `$exec </dev/null 2>&1`;
	my $rawstatus = $?;
	my $res = WIFEXITED($rawstatus)? WEXITSTATUS($rawstatus): -1;

	logInstall("\n\n###+++\nEXEC: $exec\n");
	logInstall($out);
	logInstall("###". ($res? " Exit Code: $res ":''). "+++\n\n");
	return $res;
}

# prints args to stdout, logs to install log.
# args should not have a trailing newline.
sub echolog {
	my (@stuff) = @_;
	print join("\n",@stuff)."\n";
	logInstall(join("\n",@stuff));
}

sub logInstall {
	my $string = shift;
	if ( $installLog ) {
		open(OUT,">>$installLog") or die "ERROR: Problem with file $installLog: $!\n";
		print OUT "$string\n";
		close(OUT);
	}
}

sub getArguements
{
	my @argue = @_;
	my %nvp;

	for my $maybe (@argue)
	{
		if ($maybe =~ /^.+=/)
		{
			my ($name,$value) = split("=",$maybe,2);
			$nvp{$name} = $value;
		}
		else
		{
			print "Invalid command argument: $maybe\n";
		}
	}
	return %nvp;
}

sub enable_custom_repo
{
	my ($reponame, $iscentos, $majorlevel) = @_;

	# epel: comfy for centos, not so for rh
	# repoforge: uncomfy everywhere
	if ($reponame eq "epel" )
	{
		echolog("\nEnabling EPEL repository\n");
		if ($iscentos)
		{
			execPrint("yum -y install epel-release");
		}
		else
		{
			# according to the epel docs, these two are are required prerequisites on rh 6 and 7.
			execPrint("subscription-manager repos --enable=rhel-${majorlevel}-server-optional-rpms");
			execPrint("subscription-manager repos --enable=rhel-${majorlevel}-server-extras-rpms") if ($majorlevel == 7);
			execPrint("yum -y install 'https://dl.fedoraproject.org/pub/epel/epel-release-latest-$majorlevel.noarch.rpm'");
		}
	}
	elsif ($reponame eq "gf")
	{
		echolog("\nEnabling Ghettoforge repository\n");
		execPrint("yum -y install 'http://mirror.ghettoforge.org/distributions/gf/gf-release-latest.gf.el$majorlevel.noarch.rpm'");
	}
	else
	{
		die "Cannot enable unknown custom repository \"$reponame\"!\n";
	}
}

# copy file from a to b, but only if the target is not a symlink
# if symlink, warn the user about it and request confirmation (default action: leave unchanged)
# args: source, destination, options
# returns: 1 if ok, dies on errors
sub safecopy
{
	my ($source, $destination, %options) = @_;
	die "safecopy: invalid args, $source is not a file!\n" if (!-f $source);
	die "safecopy: invalid args, $destination missing or a dir!\n" if (!$destination or -d $destination);

	if (-l $destination )
	{
		my $actualtarget = readlink($destination);
		echolog("Warning: $destination is a symbolic link pointing to $actualtarget!");
		print "\n";

		# default should be the safe behaviour, i.e. don't clobber the target
		if (input_yn("OK to leave the symbolic link $destination unchanged?"))
		{
			echolog("NOT overwriting $destination.\nThis may require manual adjustment post-install.");
			return 1;
		}
		else
		{
			echolog("Overwriting $destination (= $actualtarget) as requested.");
		}
	}
	# must work around 'text file busy' on executables (right now just wmic)
	if (-e $destination)
	{
		logInstall("replacing $destination with $source");
		unlink($destination) or die("failed to remove $destination: $!\n");
	}
	else
	{
		logInstall("copying $source to $destination");
	}
	# unfortunately, file::copy in centos/rh6 is too old for useful behaviour wrt. permissions,
	if (version->parse($File::Copy::VERSION) < version->parse("2.15"))
	{
		die "Failed to copy $source to $destination: $!\n"
				if (system("cp","-a", $source, $destination));
	}
	else
	{
		File::Copy::cp($source,$destination) or die "Failed to copy $source to $destination: $!\n";
	}
	return 1;
}

# creates a whole directory hierarchy like mkdir -p
# args: dir name
# returns: 1 if ok, dies on failure
sub safemkdir
{
	my ($dirname) = @_;
	die "safemkdir: invalid args, dirname missing!\n" if (!$dirname);

	return 1 if (-d $dirname);
	logInstall("making directory $dirname");
	# ensure we don't create unworkable dirs and files, if the parent shell
	# has a super-restrictive umask: file::path perms are subject to umask!
	my $prevmask = umask(0022);
	my $error;
	File::Path::make_path($dirname, { error => \$error,
																		mode =>  0755 } ); # umask is applied to this :-/
	if (ref($error) eq "ARRAY" and @$error)
	{
		my @errs;
		for my $issue (@$error)
		{
			push @errs, join(": ", each %$issue);
		}
		die "Could not create directory $dirname: ".join(", ",@errs)."\n";
	}
	umask($prevmask);
	return 1;
}

# trivial type/which implementation, saves us file::which or forking off a shell
# args: program name
# returns: full path or undef
sub type_which
{
	my ($needle) = @_;
	for my $maybe (split(/:/, $ENV{PATH}))
	{
		return "$maybe/$needle" if (-x "$maybe/$needle");
	}
	return undef;
}
