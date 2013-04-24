#
## $Id: Auth.pm,v 8.10 2012/11/27 00:23:20 keiths Exp $
#
#    Auth.pm - Web authorization libraries and routines
#
#    Copyright (C) 2005 Robert W. Smith
#        <rwsmith (at) bislink.net> http://www.bislink.net
#
#    Portions Copyrighted by the following entities
#    
#       Copyright (C) 2000,2001,2002 Steve Shipway
#
#       Copyright (C) 2000,2001 Sinclair InterNetworking Services Pty Ltd
#          <nmis@sins.com.au> http://www.sins.com.au
#
#	 Modified by Jan van Keulen for NMIS5.
#
#    This program is free software; you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation; either version 2 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program; if not, write to the Free Software
#    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
#
#    Enough of the legal stuff.
#
##############################################################################
#
#   Auth.pm
#   Auth.pm is a OO Perl module implementing a class module with methods
#   to enforce and perform user authentication and to a lesser degree, through
#   cooperation with another class module, provide some authorization.
#
#   I originally wrote this modules for a client that needed user-level
#   authentication and authorization with the NMIS package to segregate the
#   server groups from the router groups and then some.
#
#   The authentication routines originally came from Steve Shipway's very well 
#   written and designed (and coded) Routers2.cgi program. I took ("lifted") several
#   of his routines, verify_id, user_verfity, file_verify, ldap_verify, and
#   generate_cookie, and provided a wrapper so that they would be more easily
#   incorporated in NMIS and more generally into other web programs needing
#   user authentication.
#
#   This module is used in the following manner to enforce authentication:
#
#   use Auth;
#
#   my $AU = Auth->new();
#
#	if ($AU->Require) {
#		exit 0 unless $AU->loginout(type=>$Q->{auth_type},username=>$Q->{auth_username},
#					password=>$Q->{auth_password},headeropts=>$headeropts) ;
#


package Auth;

use vars qw(@ISA @EXPORT @EXPORT_OK %EXPORT_TAGS $VERSION );

use Exporter;

$VERSION = "1.0.0";

@ISA = qw(Exporter);

@EXPORT = qw(
	Require
	loginout
	do_force_login
	User
	SetUser
	InGroup
	CheckAccess
	CheckButton
	CheckAccessCmd
);

	#loadAccessTable
	#loadUsersTable

# Auto configure to the <nmis-base>/lib
use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;

my $C;

# import external symbols from NMIS module
use NMIS;
use func;

use Data::Dumper; 
Data::Dumper->import();
$Data::Dumper::Indent = 1;

# import additional modules
use Time::ParseDate;
use File::Basename;

# I prefer the use of the library when debugging the resulting HTML script
# either one will work
use CGI::Pretty qw(:standard form *table *Tr *td center b h1 h2);
$CGI::Pretty::INDENT = "  ";
$CGI::Pretty::LINEBREAK = "\n";

# for handling errors in javascript
use JSON;

# You should change this to be unique for your site
#
my $CHOCOLATE_CHIP = '8fhmgBC4YSVcZMnBsWtY32KQvTE9JBeuIp1y';
my $auth_user_name_regex = qr/[\w \-\.\@\`\']+/;

my $debug = 0;

#----------------------------------

sub new {
	my $this = shift;
	my $class = ref($this) || $this;
	
	my %arg = @_;	
	$C = $arg{conf},
	
	my $self = {
		_require => 1,
		dir => $arg{dir},
		user => undef,
		config => undef,
		priv => undef,
		privlevel => 0, # default all
		cookie => undef,
		groups => undef,		
	};
	bless $self, $class;
	$self->_auth_init;
	$debug = getbool($C->{auth_debug});
	
	$auth_user_name_regex	= qr/$C->{auth_user_name_regex}/ if $C->{auth_user_name_regex} ne "";
	
	return $self;
}

#----------------------------------

sub Require {
	my $self = shift;
	return $self->{_require};
}


#----------------------------------

sub _loadConf {
	my $self = shift;
	if ( not defined $C->{'<nmis_base>'} || $C->{'<nmis_base>'} eq "" ) {		
		$C = loadConfTable();
	}	
}

#----------------------------------

sub _auth_init {
	my $self = shift;
	$self->{_require} = $C->{auth_require} if defined $C->{auth_require};
	$self->_loadConf;
}

#----------------------------------

sub debug {
	my $self = shift;
	$debug = shift;
}

#----------------------------------
#
#	Check Button identifier agains priv of user
#	$AU->CheckButton('identifier') where $AU is object of user
#
sub CheckButton {
	my $self = shift;
	my $identifier = lc shift; # key of Access table is lower case

	return 1 unless $self->{_require};

	my $AC = loadAccessTable(); # get pointer of Access table 

	my $perm = $AC->{$identifier}{"level$self->{privlevel}"};
	
	logAuth("CheckButton: $self->{user}, $identifier, $perm");		

	return $perm;
}


#----------------------------------
#
#	$AU->CheckAccess('identifier','option') where identifier must be declared in Access table
#	option can be 'check' then only status is returned
#	option can be 'header' then header is printed
#
#	if result is false then message is displayed
#

sub CheckAccess {
	my $self = shift;
	my $cmd = shift;
	my $option = shift;
	
	my $C = loadConfTable(); # get pointer of NMIS config table
	
	my @cookies = ();

	# check if authentication is required
	return 1 if not $C->{auth_require};
	return 1 unless $self->{_require};

	if ( ! $self->{user} ) { 
		do_force_login("Authentication is required. Please login");
		exit 0;
	}
	
	if ( $self->CheckAccessCmd($cmd) ) {
		logAuth("CheckAccessCmd: $self->{user}, $cmd, 1") if $option ne "check";		
		return 1;
	}
	else {
		logAuth("CheckAccessCmd: $self->{user}, $cmd, 0") if $option ne "check";		
	}
	return 0 if $option eq "check"; # return the result of $self->CheckAccessCmd

	# Authorization failed--put access denied page and stop

	print header({type=>'text/html',expires=>'now'}) if $option eq 'header'; # add header

	print table(Tr(td({class=>'Error',align=>'center'},"Access denied")),
			Tr(td("Authorization required to access this function")),
			Tr(td("Requested access identifier is \'$cmd\'"))
		);

	exit 0;
}


##########################################################################
#
# The following routines in whole and in part are from Routers2.cgi and
# are copyrighted by Steve Shipway and included and used herein with
# permission. 
#
# Copyright (C) 2000, 2001, 2002 Steve Shipway
#
# The following routines are covered by this copyright and the GNU GPL.
#    verify_id
#    user_verify
#    _file_verify
#    _ldap_verify
#    generate_cookie
#
# All Java code include herein is also courtesy of Steve Shipway.
#
###########################################################################
# for security - create login page, verify username/password/cookie
# routers.conf:
#
sub get_cookie_token
{
	my $self = shift;
	my($user_name) = @_;

	my $token;
	my $remote_addr = remote_addr();	
	if( $self->{config}{auth_debug} ne '' && $self->{config}{auth_debug_remote_addr} ne '' ) {		
		$remote_addr = $self->{config}{auth_debug_remote_addr};
	}

	
	# logAuth("DEBUG: get_cookie_token: $self->{config}{auth_debug} $self->{config}{auth_debug_remote_addr}") if $debug;
	my $web_key = (defined $C->{'auth_web_key'}) ? $C->{'auth_web_key'} : $CHOCOLATE_CHIP;
	logAuth("DEBUG: get_cookie_token: remote addr=$remote_addr, username=$user_name, web_key=$web_key") if $debug;
	$token = $user_name . $remote_addr;	
	$token .= $web_key;
	$token = unpack('%32C*',$token); # generate checksum

	logAuth("DEBUG: get_cookie_token: generated token=$token") if $debug;		
	return $token;
}

sub get_cookie_domain
{
	my $self = shift;
	if ( $C->{'auth_sso_domain'} ne "" and $C->{'auth_sso_domain'} ne ".domain.com") {
		return $C->{'auth_sso_domain'};
	}
	else {		
		return;
	}
}

sub get_cookie_name
{
	my $self = shift;
	my $name = "nmis_auth".$self->get_cookie_domain;
	return $name;
}

sub get_cookie
{
	my $self = shift;
	my $cookie;
	$cookie = cookie( $self->get_cookie_name() );
	logAuth("get_cookie: got cookie $cookie") if $debug;
	return $cookie;
}

# verify_id -- reads cookies and params, returns verified username
sub verify_id {
	my $self = shift;
	# now taste cookie 
	my $cookie = $self->get_cookie();	
	# logAuth("DEBUG: verify_id: got cookie $cookie") if $debug;
	if(!defined($cookie) ) {
		logAuth("verify_id: cookie not defined");		
		logAuth("DEBUG: verify_id: cookie not defined") if $debug;		
		return ''; # not defined
	}
	
	### 2013-02-07 keiths: handling for spaces in user names required the cookie cutter to handle spaces.
	if($cookie !~ /^($auth_user_name_regex):(.+)$/) {		
		logAuth("verify_id: cookie bad format");
		logAuth("DEBUG: verify_id: cookie bad format") if $debug;		
		return ''; # bad format
	}

	my ($user_name, $checksum) = ($1,$2);
	my $token = $self->get_cookie_token($user_name);
	# logAuth("Username $user_name, checksum $checksum, token $token\n";

	logAuth("DEBUG: verify_id: $token vs. $checksum") if $debug;		
	return $user_name if( $token eq $checksum ); # yummy
	
	# bleah, nasty taste
	return '';
}
#----------------------------------

# generate_cookie -- returns a cookie with current username, expiry
sub generate_cookie {
	my $self = shift;
	my %args = @_;
	my $authuser = $args{user_name};	
	return "" if ( ! $authuser );

	my $expires = $args{expires};
	if( !defined($expires) ){
		$expires = ( $C->{auth_expire} ne "" ) ? $C->{auth_expire} : "+60min"		
	}
	
	my $value = $args{value};
	if( !exists($args{value}) ) {
		$value = $self->get_cookie_token($authuser);
		$value = $authuser . ':' . $value; # checksum		
	}

	my $domain = $self->get_cookie_domain();	
	my $cookie = cookie( {-name=> $self->get_cookie_name(), -domain=>$domain, -value=>$value, -expires=>$expires} ) ;	
	
	return $cookie;
}
#----------------------------------

# call appropriate verification routine
sub user_verify {
	my $self = shift;
	my($rv) = 0; # default: refuse
	my($u,$p) = @_;
	my $UT = loadUsersTable();
	my $exit = 0;

	my $lc_u = lc $u;
	if ($lc_u eq lc $UT->{$lc_u}{user} && $UT->{$lc_u}{admission} eq 'bypass') {
		logAuth("INFO login request for user $u bypass permitted");
		return 1;
	}

	#2011-11-14 Integrating changes from Till Dierkesmann
	if ( ! defined($C->{auth_method_1}) ) { 
		$C->{auth_method_1} = "apache"; 
	}
	elsif ($C->{auth_method_1} eq "") { 
		$C->{auth_method_1} = "apache";     
	}

	#logAuth("DEBUG: auth_method_1=$C->{auth_method_1},$C->{auth_method_2},$C->{auth_method_3}") if $debug;
	my $authCount = 0;
	for my $auth ( $C->{auth_method_1},$C->{auth_method_2},$C->{auth_method_3} ) {
		next if $auth eq '';
		++$authCount;

		if( $auth eq "apache" ) {               
			if($ENV{'REMOTE_USER'} ne "") { $exit=1; }  
			else { $exit=0; }             
		} elsif ( $auth eq "htpasswd" ) {
			$exit = $self->_file_verify($C->{auth_htpasswd_file},$u,$p,$C->{auth_htpasswd_encrypt});

		} elsif ( $auth eq "radius" ) {
			$exit = $self->_radius_verify($u,$p);

		} elsif ( $auth eq "tacacs" ) {
			$exit = $self->_tacacs_verify($u,$p);

		} elsif ( $auth eq "system" ) {
			$exit = $self->_system_verify($u,$p);

		} elsif ( $auth eq "ldaps" ) {
			$exit = $self->_ldap_verify($u,$p,1);

		} elsif ( $auth eq "ldap" ) {
			$exit = $self->_ldap_verify($u,$p,0);

		} elsif ( $auth eq "ms-ldap" ) {
			$exit = $self->_ms_ldap_verify($u,$p,0);
		
		} elsif ( $auth eq "novell-ldap" ) {
			$exit = _novell_ldap_verify($u,$p,0);
	#	} elsif ( defined( $C->{'web-htpasswd-file'} ) ) {
	#		$rv = _file_verify($C->{'web-htpasswd-file'},$u,$p,1);
	#		return $rv if($rv);
	#	} elsif ( defined( $C->{'web-md5-password-file'} ) ) {
	#		$rv = _file_verify($C->{'web-md5-password-file'},$u,$p,2);
	#		return $rv if($rv);
	#	} elsif ( defined( $C->{'web-unix-password-file'} ) ) {
	#		$rv = file_verify($C->{'web-unix-password-file'},$u,$p,3);
	#		return $rv if($rv);
		}

		if ($exit) {
			#Redundant logging
			logAuth("INFO login request of user=$u method=$auth accepted") if $authCount > 1;
			last; # done
		} else {
			logAuth("INFO login request of user=$u method=$auth failed");
		}
	}

	return $exit;
}

#----------------------------------

# verify against a password file:   username:password
sub _file_verify {
	my $self = shift;
	my($pwfile,$u,$p,$encmode) = @_;
	my($fp,$salt,$cp);

	my $crypthack;


	my $debugmessage = "DEBUG: _file_verify($pwfile,$u,$p,$encmode)\n";
	logAuth("$debugmessage") if $debug;

	$encmode = 0 if $encmode eq "plaintext";
	$encmode = 1 if $encmode eq "crypt";
	$encmode = 2 if $encmode eq "md5";

	open PW, "<$pwfile" or return 0;
	while( <PW> ) {
		if( /([^\s:]+):([^:]+)/ ) {
			if($1 eq $u) {
				$fp = $2;
				chomp $fp;
				#close PW; # we are returning whatever
				if($encmode == 0) { # unencrypted. eek!
					return 1 if($p eq $fp); 
				} elsif ($encmode == 1) { # htpasswd (unix crypt)
					if($crypthack) {
					 require Crypt::UnixCrypt;
					 $Crypt::UnixCrypt::OVERRIDE_BUILTIN = 1;
					}
					$salt = substr($fp,0,2);
					$cp = crypt($p,$salt); 
					return 1 if($fp eq $cp); 
				} elsif ($encmode == 2) { # md5 digest
					require Digest::MD5;
					return 1 if($fp eq Digest::MD5::md5($p));
				} elsif ($encmode == 3) { # unix crypt
					if($crypthack) {
					 require Crypt::UnixCrypt;
					 $Crypt::UnixCrypt::OVERRIDE_BUILTIN = 1;
					}
					$salt = substr($fp,0,2);
					$cp = crypt($p,$salt); 
					return 1 if($fp eq $cp); 
				} # add new ones here...
				if( $C->{'auth_debug'} ) {
					$debugmessage .= "Mismatch password [$u][$p]:[$fp]!=[$cp]\n";
				}
				return 0;
			} elsif( $C->{'auth_debug'} ) {
				$debugmessage .= "Mismatch user [$1][$u]\n";
			}
		} elsif( $C->{'auth_debug'} ) {
			$debugmessage .= "Bad format line $_";
		}
	}
	close PW;
	
	logAuth("$debugmessage") if $debug;

	return 0; # not found
}

#----------------------------------

# LDAP verify a username
sub _ldap_verify {
	my $self = shift;
	my($u, $p, $sec) = @_;
	my($dn,$context,$msg);
	my($ldap);
	my($attr,@attrlist);


	if($sec) {
		# load the LDAPS module
		eval { require IO::Socket::SSL; require Net::LDAPS; };
		if($@) {
			logAuth("ERROR, no IO::Socket::SSL; Net::LDAPS installed");
			return 0; 
		} # no Net::LDAPS installed
	} else {
		# load the LDAP module
		eval { require Net::LDAP; };
		if($@) {
			logAuth("ERROR, no Net::LDAP installed");
			return 0; 
		} # no Net::LDAP installed
	}

	# Connect to LDAP and verify username and password
	if($sec) {
		$ldap = new Net::LDAPS($C->{'auth_ldaps_server'});
	} else {
		$ldap = new Net::LDAP($C->{'auth_ldap_server'});
	}
	if(!$ldap) {
		logAuth("ERROR, no LDAP object created, maybe ldap server address missing in configuration of NMIS");
		return 0; 
	}
	@attrlist = ( 'uid','cn' );
	@attrlist = split( " ", $C->{'auth_ldap_attr'} )
		if( $C->{'auth_ldap_attr'} );
	
	foreach $context ( split ":", $C->{'auth_ldap_context'}  ) {
		foreach $attr ( @attrlist ) {
			$dn = "$attr=$u,".$context;
			$msg = $ldap->bind($dn, password=>$p) ;
			if(!$msg->is_error) {
				$ldap->unbind();
				return 1;
			}
		}
	}

	return 0; # not found
}

#----------------------------------
#
# Novell eDirectory LDAP verify a username
#

sub _novell_ldap_verify {
	my $self = shift;
	my($u, $p, $sec) = @_;
	my($dn,$context,$msg);
	my($ldap);
	my($attr,@attrlist);


	if($sec) {
		# load the LDAPS module
		eval { require IO::Socket::SSL; require Net::LDAPS; };
		if($@) {
			logAuth2("no IO::Socket::SSL; Net::LDAPS installed","ERROR");
			return 0; 
		} # no Net::LDAPS installed
	} else {
		# load the LDAP module
		eval { require Net::LDAP; };
		if($@) {
			logAuth2("no Net::LDAP installed","ERROR");
			return 0; 
		} # no Net::LDAP installed
	}

	# Connect to LDAP and verify username and password
	if($sec) {
		$ldap = new Net::LDAPS($C->{'auth_ldaps_server'});
	} else {
		$ldap = new Net::LDAP($C->{'auth_ldap_server'});
	}
	if(!$ldap) {
		logAuth2("no LDAP object created, maybe ldap server address missing in configuration of NMIS","ERROR");
		return 0; 
	}
	@attrlist = ( 'uid','cn' );
	@attrlist = split( " ", $C->{'auth_ldap_attr'} )
		if( $C->{'auth_ldap_attr'} );
	
	#if($debug) {
	#	logAuth("DEBUG: _novell_ldap_verify: auth_ldap_attr=(";
	#	logAuth(join(',',@attrlist);
	#	logAuth(")\n";
	#}

	# TODO: Implement non-anonymous bind

	$msg = $ldap->bind; # Anonymous bind
	if ($msg->is_error) {
		logAuth2("cant search LDAP (anonymous bind), need binddn which is uninplemented","TODO");
		logAuth2("LDAP anonymous bind failed","ERROR");
		return 0;
	}

	foreach $context ( split ":", $C->{'auth_ldap_context'}  ) {

		#logAuth("DEBUG: _novell_ldap_verify: context=$context") if $debug;

		$dn = undef;
		# Search "attr=user" in each context
		foreach $attr ( @attrlist ) {

			#logAuth("DEBUG: _novell_ldap_verify: search ($attr=$u)") if $debug;

			$msg = $ldap->search(base=>$context,filter=>"$attr=$u",scope=>"sub",attrs=>["dn"]);

			#logAuth("DEBUG: _novell_ldap_verify: search result: code=" . $msg->code . ", count=" . $msg->count . "") if $debug;

			if ( $msg->is_error ) { #|| ($msg->count != 1)) { # not Found, try next context
				next;
			}
			$dn = $msg->entry(0)->dn;
		}
		# if found, use DN to bind
		# not found => dn is undef

		return 0 unless defined($dn);

		#logAuth("DEBUG: _novell_ldap_verify: found, trying to bind as $dn") if $debug;

		$msg = $ldap->bind($dn, password=>$p) ;
		if(!$msg->is_error) {

			#logAuth("DEBUG: _novell_ldap_verify: bind success") if $debug;

			$ldap->unbind();
			return 1;
		}

		else {
			#logAuth("DEBUG: _novell_ldap_verify: bind failed with ". $msg->error . "") if $debug;

			# A bind failure in one context is fatal.
			return 0;
		}
	}

	logAuth2("LDAP user not found in any context","ERROR");
	return 0; # not found in any context
}

#----------------------------------
# Microsoft LDAP verify username/password
#
# 18-4-10 Jan v. K.
#
sub _ms_ldap_verify {
	my $self = shift;
	my($u, $p, $sec) = @_;
	my $ldap;
	my $ldap2;
	my $status;
	my $status2;
	my $entry;
	my $dn;
	
	$C->{auth_ms_ldap_debug} =  getbool($C->{auth_ms_ldap_debug});

	if($sec) {
		# load the LDAPS module
		eval { require IO::Socket::SSL; require Net::LDAPS; };
		if($@) {
			logAuth("ERROR no IO::Socket::SSL; Net::LDAPS installed");
			return 0; 
		} # no Net::LDAPS installed
	} else {
		# load the LDAP module
		eval { require Net::LDAP; };
		if($@) {
			logAuth("ERROR no Net::LDAP installed from CPAN");
			return 0; 
		} # no Net::LDAP installed
	}

	# Connect to LDAP by know (readonly) account
	if($sec) {
		$ldap = new Net::LDAPS($C->{'auth_ms_ldaps_server'});
	} else {
		$ldap = new Net::LDAP($C->{'auth_ms_ldap_server'});
	}
	if(!$ldap) {
		logAuth("ERROR no LDAP object created, maybe ms_ldap server address missing in configuration of NMIS");
		return 0; 
	}

	# bind LDAP for request DN of user
	$status = $ldap->bind("$C->{'auth_ms_ldap_dn_acc'}",password=>"$C->{'auth_ms_ldap_dn_psw'}");
	if ($status->code() ne 0) {
		logAuth("ERROR LDAP validation of $C->{'auth_ms_ldap_dn_acc'}, error msg ".$status->error()." ");
		return 0;
	}

	logAuth("DEBUG LDAP Base user=$C->{'auth_ms_ldap_dn_acc'} authorized") if $C->{auth_ms_ldap_debug};

	for my $attr ( split ',',$C->{'auth_ms_ldap_attr'}) {

		logAuth("DEBUG LDAP search, base=$C->{'auth_ms_ldap_base'},".
						"filter=${attr}=$u, attr=distinguishedName") if $C->{auth_ms_ldap_debug};

		my $results = $ldap->search(scope=>'sub',base=>"$C->{'auth_ms_ldap_base'}",filter=>"($attr=$u)",attrs=>['distinguishedName']);

		##
		writeTable(dir=>'var',name=>"nmis-ldap-debug",data=>$results) if $C->{auth_ms_ldap_debug};
		##

		if (($entry = $results->entry(0))) {
			$dn = $entry->get_value('distinguishedName');
		} else {
			logAuth("DEBUG LDAP search failed") if $C->{auth_ms_ldap_debug};
		}
	}

	if ($dn eq '') {
		logAuth("DEBUG user $u not found in Active Directory") if $C->{auth_ms_ldap_debug};
		$ldap->unbind();
		return 0;
	}

	my $d = $dn;
	$d =~ s/\\//g;
	logAuth("DEBUG LDAP found distinguishedName=$d") if $C->{auth_ms_ldap_debug};

	# check user

	# Connect to LDAP and verify username and password
	if($sec) {
		$ldap2 = new Net::LDAPS($C->{'auth_ms_ldaps_server'});
	} else {
		$ldap2 = new Net::LDAP($C->{'auth_ms_ldap_server'});
	}
	if(!$ldap2) {
		logAuth("ERROR no LDAP object created, maybe ms_ldap server address missing");
		return 0; 
	}

	$status2 = $ldap2->bind("$dn",password=>"$p");
	logAuth("DEBUG LDAP bind dn $d password $p status ".$status->code()) if $C->{auth_ms_ldap_debug};
	if ($status2->code eq 0) {
		# permitted
		$ldap->unbind();
		$ldap2->unbind();
		return 1;
	}

	$ldap->unbind();
	$ldap2->unbind();

	return 0; # not found
}


##########################################################################
#
# The following routines were inspired as part of Routers2.cgi but
# but where completely gutted to suit my purposes. As they are no
# longer recognizable by Steve I take full responsibility of these
# modules and the maintenance.
#
# Copyright (C) 2005 Robert W. Smith
#
# The following routines are covered by this copyright and the GNU GPL.
# do_login -- output HTML login form that submits to top level
#
sub do_login {
	my $self = shift;
	my %args = @_;
	my $config = $args{conf};
	my $msg = $args{msg};

	# this is sent if auth = y and page = top (or blank),
	# or if page = login
	my $url = self_url();
	if( $config ne '' ) {
		if( index($url, '?') == -1 ) {
			$url .= "?conf=$config";
		} else {
			$url .= "&conf=$config";
		}
	}

	if( http("X-Requested-With") eq "XMLHttpRequest" )
	{
		# forward url will have a function in it, we want to go back to regular nmis
		# my $url_no_forward = url(-base=>1) . $C->{'<cgi_url_base>'} . "/nmiscgi.pl?auth_type=login$configfile_name";			
		my $ret = { name => "JSONRequestError", message => "Authentication Error" };
		my $json_data = to_json( $ret ); #, { pretty => 1 } );

    print <<EOHTML;
Status: 405 Method Not Allowed
Content-type: application/json

EOHTML
    print $json_data;
    return;
	}
	my $cookie = $self->generate_cookie(user_name => "remove", expires => "now", value => "remove" );
	logAuth("DEBUG: do_login: sending cookie to remove existing cookies=$cookie") if $debug;
	print header(-target=>"_top", -type=>"text/html", -expires=>'now', -cookie=>[$cookie]);

	print qq
|<!DOCTYPE html>
<html>
  <head>
    <title>$C->{auth_login_title}</title>
    <meta http-equiv="Content-Type" content="text/html; charset=iso-8859-1" />
    <meta http-equiv="Pragma" content="no-cache" />
    <meta http-equiv="Cache-Control" content="no-cache, no-store" />
    <meta http-equiv="Expires" content="-1" />
    <meta http-equiv="Robots" content="none" />
    <meta http-equiv="Googlebot" content="noarchive" />
    <link type="image/x-icon" rel="shortcut icon" href="$C->{'nmis_favicon'}" />    
    <link type="text/css" rel="stylesheet" href="$C->{'jquery_ui_css'}" />
    <link type="text/css" rel="stylesheet" href="$C->{'styles'}" />
    <script src="$C->{'jquery'}" type="text/javascript"></script>    
    <script src="$C->{'jquery_ui'}" type="text/javascript"></script>
  </head>
  <body>
|;
	
	print qq|
  <div id="login_frame">
    <div id="login_dialog" class="ui-dialog ui-widget ui-widget-content ui-corner-all">
|;

	print do_login_banner();

	print start_form({method=>"POST", action=>"?", target=>"_top"});

	print start_table({class=>""});
	print Tr(th({class=>'header',colspan=>'2'},"Authentication required"));

	print Tr(td({class=>'info Plain',colspan=>'2'},"Please log in with your appropriate username and password in order to gain access to this system"));
	
	print Tr(td({class=>'info Plain'},"Username") . td({class=>'info Plain'},textfield({name=>'auth_username'})));
	print Tr(td({class=>'info Plain'},"Password") . td({class=>'info Plain'},password_field({name=>'auth_password'}) ));
	print Tr(td({class=>'info Plain'},"&nbsp;") . td({class=>'info Plain'},submit({name=>'login',value=>'Login'}) ));
		
	if ( $C->{'auth_sso_domain'} ne "" and $C->{'auth_sso_domain'} ne ".domain.com" ) {
		print Tr(td({class=>"info",colspan=>'2'}, "Single Sign On configured with \"$C->{'auth_sso_domain'}\""));
	}
	
	print Tr(td({colspan=>'2'},p({style=>"color: red"}, "&nbsp;$msg&nbsp;"))) if $msg ne "";

	print end_table;

	print hidden(-name=>'conf', -default=>$config, -override=>'1');

	# put query string parameters into the form so that they are picked up by Vars (because it only takes get or post not both)	
	my @qs_params = param();	
	foreach my $key (@qs_params) {
		# logAuth("adding $key ".param($key)."\n";
		if( $key !~ /conf|auth_type|auth_username|auth_password/ ) {
			print hidden(-name=>$key, -default=>param($key),-override=>'1');	
		}			
	}

	print end_form;

	print "    </div>\n";
	print "  </div>\n";

	print end_html;
}

##############################################################################
#
# The java script herein is courtesy of the Steve Shipway and is copyrighted
# by him.
# 
# do_force_login -- output HTML that sends top level to login page
#
sub do_force_login {
	my $self = shift;
	my %args = @_;
	my $config = $args{conf};
	my($javascript);
	my($err) = shift;

	if( $config ne '' ){
		$config = "&conf=$config";
	}

	my $url = url(-base=>1) . $C->{'<cgi_url_base>'} . "/nmiscgi.pl?auth_type=login$config";	

	# if this request is coming through an AJAX'Y method, respond in a different mannor that commonV8.js will understand
	# and redirect for us
	if( http("X-Requested-With") eq "XMLHttpRequest" )
	{		
		my $url_no_forward = $url;
		my $ret = { name => "JSONRequestError", message => "Authentication Error", redirect_url => $url_no_forward };
		my $json_data = to_json( $ret ); #, { pretty => 1 } );

    print <<EOHTML;
Status: 405 Method Not Allowed
Content-type: application/json

EOHTML
    print $json_data;
    return;
	}

	$javascript = "function redir() { ";
#	$javascript .= "alert('$err'); " if($err);
	$javascript .= " window.location = '" . $url . "'; }";

	$javascript = "function redir() {} " if($C->{'web-auth-debug'});

	print header({ target=>'_top', expires=>"now" })."\n";
	print start_html({ title =>"Login Required",
						expires => "now",  script => $javascript,
						onload => "redir()", bgcolor=>'#CFF' }),"\n";
	print h1("Authentication required")."\n";
	print "Please ".a({href=>$url},"login")	." before continuing.\n";

	print "<!-- $err -->\n";
	print end_html;
}

#----------------------------------

# do_logout -- set auth cookie to blank, expire now, and redirect to top
#
sub do_logout {	
	my $self = shift;
	my %args = @_;
	my $config = $args{conf};

	# Javascript that sets window.location to login URL
	my $javascript = "function redir() { window.location = '" . url(-full=>1) . "'; }";
	my $cookie = $self->generate_cookie(user_name => $self->{user}, expires => "now", value => "" );

	logAuth("INFO logout of user=$self->{user}");

	print header({ -target=>'_top', -expires=>"5s", -cookie=>[$cookie] })."\n";
	#print start_html({ 
	#	-title =>"Logout complete",
	#	-expires => "5s",  
	#	-script => $javascript, 
	#	-onload => "redir()",		
	#	-style=>{'src'=>"$C->{'<menu_url_base>'}/css/dash8.css"}
	#	}),"\n";

	print qq
|<!DOCTYPE html>
<html>
  <head>
    <title>Logout complete</title>
    <meta http-equiv="Content-Type" content="text/html; charset=iso-8859-1" />
    <meta http-equiv="Pragma" content="no-cache" />
    <meta http-equiv="Cache-Control" content="no-cache, no-store" />
    <meta http-equiv="Expires" content="-1" />
    <meta http-equiv="Robots" content="none" />
    <meta http-equiv="Googlebot" content="noarchive" />
    <link type="image/x-icon" rel="shortcut icon" href="$C->{'nmis_favicon'}" />    
    <link type="text/css" rel="stylesheet" href="$C->{'jquery_ui_css'}" />
    <link type="text/css" rel="stylesheet" href="$C->{'styles'}" />
    <script src="$C->{'jquery'}" type="text/javascript"></script>    
    <script src="$C->{'jquery_ui'}" type="text/javascript"></script>
    <script type="text/javascript">//<![CDATA[
$javascript
//]]></script>
  </head>
  <body onload="redir()" expires="10s">
|;

	print qq|
  <div id="login_frame">
    <div id="login_dialog" class="ui-dialog ui-widget ui-widget-content ui-corner-all">
|;

	print do_login_banner();

	print start_table();
	print Tr(td({class=>"info Plain"}, p(h2("Logged out of system") .
	p("Please " . a({href=>url(-full=>1) . ""},"go back to the login page") ." to continue."))));

	print end_table;

	print "    </div>\n";
	print "  </div>\n";

	print end_html;
}

#####################################################################
#
# The following routines are courtesy of Robert W. Smith, copyrighted
# and covered under the GNU GPL.
#
sub do_login_banner {
	my $self = shift;
	my @banner = ();
	
	my $logo = qq|<a href="http://www.opmantek.com"><img height="20px" width="20px" class="logo" src="$C->{'nmis_favicon'}"/></a>|;

	push @banner,div({class=>'ui-dialog-titlebar ui-dialog-header ui-corner-all ui-widget-header lrg'},$logo, "NMIS Network Management Information System");
		
	return @banner;
}


#####################################################################
#
# The following routines are courtesy of the NMIS source and copyrighted
# by Sinclair Internetworking Ltd Pty and covered under the GNU GPL.
#
sub get_time {
        # pull the system timezone and then the local time
        if ($^O =~ /win32/i) { # could add timezone code here
                return scalar localtime;
        }
        else { # assume UNIX box - look up the timezone as well.
		my $lt = scalar localtime;
		$lt =~ s/  / /;
                return uc((split " ", `date`)[4]) . " " . $lt;
        }
}


#####################################################################
#
# 5-10-06, Jan v. K.
#

sub _radius_verify {
	my $self = shift;
	my($user, $pswd) = @_;

	eval { require Authen::Simple::RADIUS; }; # installed from CPAN
	if($@) {
		logAuth("ERROR, no Authen::Simple::RADIUS installed");
		return 0; 
	} # no Authen::Simple::RADIUS installed

	my ($host,$port) = split(/:/,$C->{auth_radius_server});
	if ($host eq "") {
		logAuth("ERROR, no radius server address specified in configuration of NMIS");
	} elsif ($C->{auth_radius_secret} eq "") {
		logAuth("ERROR, no radius secret specified in configuration of NMIS");
	} else {
		$port = 1645 if $port eq "";
		my $radius = Authen::Simple::RADIUS->new(
			host   => $host,
			secret => $C->{auth_radius_secret},
			port => $port
		); 
		if ( $radius->authenticate( $user, $pswd ) ) {
	        return 1;
		}
	}
	return 0;
}

#####################################################################
#

sub _tacacs_verify {
	my $self = shift;
	my($user, $pswd) = @_;


	eval { require Authen::TacacsPlus; }; # installed from CPAN
	if($@) {
		logAuth("ERROR, no Authen::TacacsPlus installed");
		return 0; 
	} # no Authen::TacacsPlus installed

	my ($host,$port) = split(/:/,$C->{auth_tacacs_server});
	if ($host eq "") {
		logAuth("ERROR, no tacacs server address specified in configuration of NMIS");
	} elsif ($C->{auth_tacacs_secret} eq "") {
		logAuth("ERROR, no tacacs secret specified in configuration of NMIS");
	} else {
		$port = 49 if $port eq "";
		my $tacacs = new Authen::TacacsPlus(
			Host => $host,
			Key => $C->{auth_tacacs_secret},
		);
		if ( $tacacs->authen($user,$pswd)) {
			$tacacs->close();
			return 1;
		}
		$tacacs->close();
	}
	return 0;
}

#####################################################################
#
# 5-03-07, Jan v. K.
#
# check login - logout - go

sub loginout {
	my $self = shift;
	my %args = @_;
	my $type = lc($args{type});
	my $username = $args{username};
	my $password = $args{password};
	my $config = $args{conf};
	#my $config = $self->{config};
	#my $config = $self->{config}{configfile_name};
	my $headeropts = $args{headeropts};
	my @cookies = ();

	logAuth("DEBUG: loginout type=$type username=$username") if $debug;
	
	#2011-11-14 Integrating changes from Till Dierkesmann
	### 2013-01-22 markd, fixing Auth to use Cookies!
	if($ENV{'REMOTE_USER'} and ($C->{auth_method_1} eq "" or $C->{auth_method_1} eq "apache") ) {             
		$username=$ENV{'REMOTE_USER'};
		if( $type eq 'login' ) {
			$type = ""; #apache takes care of showing the login screen	
		}		
  }
	
	if ( lc $type eq 'login' ) {
		$self->do_login();
		return 0;
	}

	if (defined($username) && $username ne '') { # someone is trying to log in
		logAuth("DEBUG: verifying $username") if $debug;
		if( $self->user_verify($username,$password)) {
			#logAuth("DEBUG: user verified $username") if $debug;
			#logAuth("self.privilevel=$self->{privilevel} self.config=$self->{config} config=$config") if $debug;

			# login accepted, set privs
			$self->SetUser($username);

			# handle default privileges or not.
			if ( $self->{priv} eq "" and ( $C->{auth_default_privilege} eq "" or $C->{auth_default_privilege} eq "false" ) ) { 
				$self->do_login(msg=>"Privileges NOT defined, please contact your administrator");
				return 0;	
			}

			# check the name of the NMIS config file specified on url
			# only bypass for administrator
			if ($self->{privlevel} gt 1 and $self->{config} ne '' and $config ne $self->{config}) {
				$self->do_login(msg=>"Invalid config file specified on url");
				return 0;
			}

			logAuth("user=$self->{user} logged in with config=$config");
			logAuth("DEBUG: loginout user=$self->{user} logged in with config=$config") if $debug;

		} else { # bad login: force it again
			$self->do_login(msg=>"Invalid username/password combination");
			return 0;
		}
	} 
	else { # check cookie
		logAuth("DEBUG: valid session? check cookie") if $debug;		

		$username = $self->verify_id();
		if( $username eq '' ) { # invalid cookie
			logAuth("DEBUG: invalid session ") if $debug;		
			#$self->do_login(msg=>"Session Expired or Invalid Session");
			$self->do_login(msg=>"");
			return 0;
		}

		$self->SetUser( $username );
		logAuth("DEBUG: cookie OK") if $debug;
	}

	# logout has to be down here because we need the username loaded to generate the correct cookie 
	if(lc $type eq 'logout') {
		$self->do_logout(); # bye
		return 0;
	}

	# user should be set at this point, if not then redirect
	unless ($self->{user}) {
		logAuth("DEBUG: loginout forcing login, shouldn't have gotten this far") if $debug;
		$self->do_login();
		return 0;
	}
	
	# generate the cookie if $self->user is set
	if ($self->{user}) {		
    push @cookies, $self->generate_cookie(user_name => $self->{user});
  	logAuth("DEBUG: loginout made cookie $cookies[0]") if $debug;
	}
	$self->{cookie} = \@cookies;
	$headeropts->{-cookie} = [@cookies];
	return 1; # all oke
}

#----------------------------------

#sub loadAccessTable {
#	return loadTable(dir=>'conf',name=>'Access'); # tables cashed by func.pm
#}

#----------------------------------

#sub loadUsersTable {
#	return loadTable(dir=>'conf',name=>'Users');
#}

#----------------------------------

#sub loadPrivMapTable {
#
#	return loadTable(dir=>'conf',name=>'PrivMap');
#}

#----------------------------------

# check if user logged in

sub User {
	my $self = shift;
	return $self->{user};
}

#----------------------------------

# Set the user and read in the user privilege and groups
#
sub SetUser {
	my $self = shift;
	$self->{_require} = 1;
	my $user = shift;
	if ( $user ) {
		$self->{user} = $user; # username
		# set default privileges to lowest level
		$self->{priv} = "anonymous";
		$self->{privlevel} = 5;
		$self->_GetPrivs($self->{user});
		return 1;
	}
	else {
		return 0;
	}
}

#----------------------------------

# check if the group is in the user's group list
#
sub InGroup {
	my $self = shift;
	my $group = shift;
	return 1 unless $self->{_require};
	# If user can see all groups, they immediately pass
	if ( $self->{groups} eq "all" ) {
		logAuth("InGroup: $self->{user}, all $group, 1") if $debug;
		return 1;
	}
	return 0 unless defined $group or $group;
	foreach my $g (@{$self->{groups}}) {
		logAuth("  DEBUG AUTH: @{$self->{groups}} g=$g group=$group") if $debug;
		if ( lc($g) eq lc($group) ) {
			logAuth("InGroup: $self->{user}, $group, 1") if $debug;
			return 1;
		}

	}
	logAuth("InGroup: $self->{user}, $group, 0") if $debug;
	return 0;
}

#----------------------------------

#	Check Access identifier agains priv of user
sub CheckAccessCmd {
	my $self = shift;
	my $command = lc shift; # key of table is lower case

	return 1 unless $self->{_require};

	my $AC = loadAccessTable();
	
	my $perm = $AC->{$command}{"level$self->{privlevel}"};
	
	logAuth("CheckAccessCmd: $self->{user}, $command, $perm") if $debug;		

	return $perm;
}

#----------------------------------

# Private routines go here
#
# _GetPrivs -- load and parse the conf/Users.nmis file
# also loads conf/PrivMap.nmis to map the privilege to a
# numeric privilege level.
#
sub _GetPrivs {
	my $self = shift;
	my $user = lc shift;

	my $GT = loadGroupTable();
	my $UT = loadUsersTable();
	my $PMT = loadPrivMapTable();

	if ( exists $UT->{$user}{privilege} and $UT->{$user}{privilege} ne ""  ) {
		$self->{priv} = $UT->{$user}{privilege};
	}
	else {
		if ( $C->{auth_default_privilege} ne "" and $C->{auth_default_privilege} ne "false" ) { 
			$self->{priv} = $C->{auth_default_privilege};
			$self->{privlevel} = 5;
			logAuth("INFO User \"$user\" not found in Users table, assigned default privilege $C->{auth_default_privilege}");
		}
		else {
			$self->{priv} = "";			
			$self->{privlevel} = 5;
			logAuth("INFO User \"$user\" not found in Users table, no default privilege configured");	
			return 0;
		}
	}
		
	if ( ! exists $PMT->{$self->{priv}} and $PMT->{$self->{priv}}{level} eq "" ) {
		logAuth("Privilege $self->{priv} not found for user \"$user\" ");
		$self->{priv} = "";
		$self->{privlevel} = 5;
		return 0;
	}

	$self->{privlevel} = 5;
	if ( $PMT->{$self->{priv}}{level} ne "" ) {
		$self->{privlevel} = $PMT->{$self->{priv}}{level};
	}
	logAuth("INFO User \"$user\" has priv=$self->{priv} and privlevel=$self->{privlevel}") if $debug;

	dbg("USER groups \n".Dumper($C->{group_list}) );

	my @groups = split /,/, $UT->{$user}{groups};
	if ( not @groups and $C->{auth_default_groups} ne "" ) {
		@groups = split /,/, $C->{auth_default_groups};
		logAuth("INFO Groups not found for User \"$user\" using groups configured in Config.nmis->auth_default_groups");	
	}

	if ( grep { $_ eq 'all' } @groups) {
		@{$self->{groups}} = sort split(',',$C->{group_list});
		# put the virtual network group on the list
		push @{$self->{groups}}, "network"; 
	} elsif ( $UT->{$user}{groups} eq "none" or $UT->{$user}{groups} eq "" ) {
		@{$self->{groups}} = [];
	} else {
		# note: the main health status graphs uses the implied virtual group network,
  	# this group must be explicitly stated if you want to see this graph
		@{$self->{groups}} = @groups;
	}
	map { stripSpaces($_) } @{$self->{groups}};

	return 1;
}

#----------------------------------

#sub AUTOLOAD {
#	my $self = shift;
#	my $type = ref($self) || croak "$self is not an object\n";
#	my $name = our $AUTOLOAD;
#	$name =~ s/.*://;
#	unless (exists $self->{$name} ) {
#		croak "cant access $name field in object $type\n";
#	}
#	if (@_) {
#		return $self->{$name} = shift;
#	} else {
#		return $self->{$name};
#	}
#}

1;
