#!/usr/bin/perl
#
## $Id: menu.pl,v 8.23 2012/08/13 05:05:00 keiths Exp $
#
#  Copyright 1999-2011 Opmantek Limited (www.opmantek.com)
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

package main;
#use CGI::Debug( report => 'everything', on => 'anything' );

use FindBin;
use lib "$FindBin::Bin/../lib";
use Data::Dumper;

use NMIS;
use func;
use Sys;
use NMIS::Modules;

use JSON;

# Prefer to use CGI::Pretty for html processing
# use CGI::Pretty qw(:standard *table *Tr *td *form *Select *div *ul *li);
#use CGI qw(:standard *table *Tr *td *form *Select *div *ul *li);

use CGI qw(:standard *table *Tr *td *form *Select *div *form escape *ul *li);

# declare holder for CGI objects
use vars qw($q $Q $C $AU);
$q = new CGI; # This processes all parameters passed via GET and POST

$Q = $q->Vars; # values in hash

# load NMIS configuration table
$C = loadConfTable(conf=>$Q->{conf},debug=>$Q->{debug});
$Q->{conf} = (exists $Q->{conf} and $Q->{conf} ) ?  $Q->{conf} : $C->{conf};

# set some defaults
my $widget_refresh = $C->{widget_refresh_time} ? $C->{widget_refresh_time} : 180 ;

# NMIS Authentication module
use Auth;

# variables used for the security mods
use vars qw($headeropts); $headeropts = {type=>'text/html',expires=>'now'};
$AU = Auth->new(conf => $C);  # Auth::new will reap init values from NMIS::config

if ($AU->Require) {
	exit 0 unless $AU->loginout(type=>$Q->{auth_type},username=>$Q->{auth_username},
					password=>$Q->{auth_password},headeropts=>$headeropts) ;
	$user = $AU->{user};
}

# dispatch the request
if ($Q->{act} eq 'menu_bar_site') {			menu_bar_site(); # vertical parent menu
} elsif ($Q->{act} eq 'menu_bar_portal') {	menu_bar_portal(); # hr portal select
} elsif ($Q->{act} eq 'menu_panel_node') {	menu_panel_node();
} elsif ($Q->{act} eq 'menu_about_view') {	menu_about_view();
} elsif ( exists ($Q->{POSTDATA}) ) {	save_window_state();
} else { notfound(); }

sub notfound {
	print header({-type=>"text/html",-expires=>'now'});
	print "Menu; ERROR, act=$Q->{act}<br> \n";
	print "Request not found\n";
}

#============================================================================


# print the menu in boring HTML <ul><li>
# CGI ::Pretty would not format this  so I hardcoded the ident and recurse level to verify correct operation
# remove for production .
# this is a recursive function
# needs a tidyup..TBD
sub print_array_list {
	my $aref = shift;
	my $level = shift;
	my $arrow = shift;				# flag to print the directional arrow
	my $a = [];

	my $ident;
	foreach ( 0 .. $level) { $ident.='  '};


	while ( defined ( $a = shift @{$aref}) ) {
		if ( not ref $a ) {
			# current is a  header or item string
			# add the onclick handler if a href (ie) dont jquery it later, ccheaper and easier to cleanup here
			# ignore any links that have a 'target' attribute
			if ( $a =~ /href=/i and $a !~ /target/i ) {
				substr($a, index($a, '<a '), 3) = qq|<a onClick="clickMenu(this);return false" |;
			}
			# lookahead and test if the next arg is a string or ref
			# if a ref, dont add end_li tag, else wrap this in <li>xx</li>
			if ( not scalar @{$aref} ) {
				# finished the list
				print "$ident<li>$a</li>\n";
			}
			elsif ( not ref $aref->[0] ) {					# look ahead to the next item on the list
				# next is a list item
				print "$ident<li>$a</li>\n";
			}
			else {
				# next is a ref, so dont complete </li>
				# so we recurse and come back shortly
				print "$ident<li>$a";
			}
		}
		else {							# we have a reference, so recurse to it
			my $id = $level;
			$id++;
			my $id2;
			foreach ( 0 .. $id) { $id2.='  '};
			# print  the directional arrow first.
			if ( $arrow) { print qq|<img style="vertical-align:middle;" src="$C->{'<menu_url_base>'}/img/arrow_right_black.gif">|; }
			print "\n<ul>\n";		# and wrap it in a <ul>...</ul> tags
			print_array_list( $a, $id+1, 1 );					# recursive - pass the aref to ourslves
			print "</ul>\n$ident</li>\n";			#  arrow is printed on al sub menus
		}
	}
}


# VERTICAL SIDEBAR menu
# I have set these up as 'push @x, list of arrays
# format is
# menu[0] = ref to anon list( 'header string', ref to submenu items  );
# menu[1] = ref to anon list( 'header string', ref to submenu items  );
# a nested menu
# menu[2] = ref to anon list( 'header string', ( ref to anon list( 'header string', ref to submenu items  ));
#
# These are hardcoded here as a development exercise
# in reality the menu arrays should be generated by the user auth modules
# as that will provide a list of menu buttons, based on user rights

sub menu_bar_site {

	print header({-type=>"text/html",-expires=>'now'});
	print		$q->start_ul({ class=>"jd_menu"});
	print_array_list( menu_site(), 1 , 0 );
	print $q->end_ul();

	
	sub menu_site {
		my $M = NMIS::Modules->new(module_base=>$C->{'<opmantek_base>'});
		my $modules = $M->getModules();

		my @menu_site = [];

		my @netstatus;		 
		push @netstatus, qq|<a id='ntw_metrics' href="network.pl?conf=$Q->{conf}&amp;refresh=$widget_refresh&amp;act=network_summary_metrics">Metrics</a>|;
		push @netstatus, qq|<a id='ntw_graph' href="network.pl?conf=$Q->{conf}&amp;refresh=$widget_refresh&amp;act=network_metrics_graph">Network Metric Graphs</a>|;
		push @netstatus, qq|<a id='ntw_health' href="network.pl?conf=$Q->{conf}&amp;refresh=$widget_refresh&amp;act=network_summary_health">Network Status and Health</a>|;
		push @netstatus, qq|<a id='ntw_summary' href="network.pl?conf=$Q->{conf}&amp;refresh=$widget_refresh&amp;act=network_summary_large">Network Status and Health by Group</a>|;
		push @netstatus, qq|<a id='src_events' href="events.pl?conf=$Q->{conf}&amp;act=event_table_list">Current Events</a>|;
		push @netstatus, qq|<a id='nmislogs' href="logs.pl?conf=$Q->{conf}&amp;act=log_file_view&amp;lines=25&amp;logname=Event_Log">Network Events</a>|;
		push @netstatus, qq|<a id='ntw_map' href="$modules->{opMaps}{link}?widget=true">Network Maps</a>| if $M->moduleInstalled(module => "opMaps");
		
		push @menu_site,(qq|Network Status|,[ @netstatus ]);		


		my @netperf;		 
		push @netperf, qq|<a target='ntw_ipsla' href="$C->{ipsla}?conf=$Q->{conf}">IPSLA Monitor</a>|;
		push @netperf, qq|<a id='ntw_overview' href="network.pl?conf=$Q->{conf}&amp;refresh=$widget_refresh&amp;act=network_summary_allgroups">All Groups</a>|;
		push @netperf, qq|<a id='ntw_overview' href="network.pl?conf=$Q->{conf}&amp;refresh=$widget_refresh&amp;act=network_interface_overview">OverView</a>|;
		push @netperf, qq|<a id='ntw_top10' href="network.pl?conf=$Q->{conf}&amp;refresh=$widget_refresh&amp;act=network_top10_view">Top 10</a>|;
		push @netperf, qq|<a id='ntw_links' href="links.pl?conf=$Q->{conf}&amp;act=network_links_view">Link List</a>|;
		
		### 2012-11-26 keiths, Optional opFlow Widgets if opFlow Installed.
		if ($M->moduleInstalled(module => "opFlow") ) {
			push @netperf, qq|--------|;
			push @netperf, qq|<a id='ntw_flowSummary' href="$modules->{opFlow}{link}?widget=true&amp;act=widgetflowSummary">Application Flows</a>|;
			push @netperf, qq|<a id='ntw_topnApps' href="$modules->{opFlow}{link}?widget=true&amp;act=widgetTopnApps">TopN Applications</a>|;
			push @netperf, qq|<a id='ntw_topnAppSrc' href="$modules->{opFlow}{link}?widget=true&amp;act=widgetTopnAppSrc">TopN Application Sources</a>|;
			push @netperf, qq|<a id='ntw_topnTalkers' href="$modules->{opFlow}{link}?widget=true&amp;act=widgetTopnTalkers">TopN Talkers</a>|;
			push @netperf, qq|<a id='ntw_topnListeners' href="$modules->{opFlow}{link}?widget=true&amp;act=widgetTopnListeners">TopN Listeners</a>|;
		}
		push @menu_site,(qq|Network Performance|,[ @netperf ]);		

				
		#Handling optional items in the menu, depending on the config.
		my @nettools;		 
		push @nettools, qq|<a id='tools_ping' href="tools.pl?conf=$Q->{conf}&amp;act=tool_system_ping">Ping</a>|;
		push @nettools, qq|<a id='tools_trace' href="tools.pl?conf=$Q->{conf}&amp;act=tool_system_trace">Traceroute</a>|;
		push @nettools, qq|<a id='tools_lft' href="tools.pl?conf=$Q->{conf}&amp;act=tool_system_lft">LFT</a>| if $C->{view_lft} eq 'true'; 
		push @nettools, qq|<a id='tools_mtr' href="tools.pl?conf=$Q->{conf}&amp;act=tool_system_mtr">MTR</a>| if $C->{view_mtr} eq 'true';
		push @nettools, qq|<a id='tls_snmp' href="snmp.pl?conf=$Q->{conf}&amp;act=snmp_var_menu">SNMP Tool</a>|;
													
		push @nettools,	( qq|IP Tools|,
											[
												qq|<a id='tls_ip' href="ip.pl?conf=$Q->{conf}&amp;act=tool_ip_menu">IP Calc</a>|,
												qq|<a id='tls_dns_host' href="tools.pl?conf=$Q->{conf}&amp;act=tool_system_dns&amp;dns=host">IP host</a>|,
												qq|<a id='tls_dns_dns' href="tools.pl?conf=$Q->{conf}&amp;act=tool_system_dns&amp;dns=dns">IP dns</a>|,
												qq|<a id='tls_dns_arpa' href="tools.pl?conf=$Q->{conf}&amp;act=tool_system_dns&amp;dns=arpa">IP arpa</a>|,
												qq|<a id='tls_dns_loc' href="tools.pl?conf=$Q->{conf}&amp;act=tool_system_dns&amp;dns=loc">IP loc</a>|
											]
										);

		push @menu_site,(qq|Network Tools|,[ @nettools ]);		

		# Potential Future Capabilities
		#push @menu_site,	( qq|Business Dashboard|);
		#push @menu_site,	( qq|Applications Dashboard|);
		
		my @reports;
		#push @reports, qq|<a id='opReports' href="$modules->{opReports}{link}?widget=true">opReports</a>| if $M->moduleInstalled(module => "opReports");

		push @reports,	( qq|Current|,
											[ qq|<a id='dyn_available' href="reports.pl?conf=$Q->{conf}&amp;act=report_dynamic_avail">Availability</a>|,
												qq|<a id='dyn_health' href="reports.pl?conf=$Q->{conf}&amp;act=report_dynamic_health">Health</a>|,
												qq|<a id='dyn_response' href="reports.pl?conf=$Q->{conf}&amp;act=report_dynamic_response">Response Time</a>|,
												qq|<a id='dyn_top10' href="reports.pl?conf=$Q->{conf}&amp;act=report_dynamic_top10">Top 10</a>|,
												qq|<a id='dyn_outage' href="reports.pl?conf=$Q->{conf}&amp;act=report_dynamic_outage">Outage</a>|,
												qq|<a id='dyn_port' href="reports.pl?conf=$Q->{conf}&amp;act=report_dynamic_port">Port Counts</a>|
											]
										);
		push @reports,	( qq|History|,
											[ qq|<a id='strd_available' href="reports.pl?conf=$Q->{conf}&amp;act=report_stored_avail">Availability</a>|,
												qq|<a id='strd_health' href="reports.pl?conf=$Q->{conf}&amp;act=report_stored_health">Health</a>|,
												qq|<a id='strd_response' href="reports.pl?conf=$Q->{conf}&amp;act=report_stored_response">Response Time</a>|,
												qq|<a id='strd_top10' href="reports.pl?conf=$Q->{conf}&amp;act=report_stored_top10">Top 10</a>|,
												qq|<a id='strd_outage' href="reports.pl?conf=$Q->{conf}&amp;act=report_stored_outage">Outage</a>|,
												qq|<a id='strd_port' href="reports.pl?conf=$Q->{conf}&amp;act=report_stored_port">Port Counts</a>|
											]
										);
												
		push @menu_site,(qq|Reports|,[ @reports ]);		
										
		# Potential Future Capabilities
		#push @menu_site,	( qq|Traffic Monitor|,
		#										[
		#											qq|<a id='tm_netflow' href="#">NetFlow</a>|
		#										]
		#									);
		
		push @menu_site,	( qq|Service Desk|,
												[
													( qq|Alerts|,
														[
															qq|<a id='src_events' href="events.pl?conf=$Q->{conf}&amp;act=event_table_list">Events</a>|,
															qq|<a id='src_outages' href="outages.pl?conf=$Q->{conf}&amp;act=outage_table_view">Outages</a>|,
															qq|<a id='src_links' href="tables.pl?conf=$Q->{conf}&amp;act=config_table_menu&amp;table=Links">Links</a>|
														]
													),
													(	qq|Find|,
														[	qq|<a id='find_node' href="find.pl?conf=$Q->{conf}&amp;act=find_node_menu">Node</a>|,
															qq|<a id='find_interface' href="find.pl?conf=$Q->{conf}&amp;act=find_interface_menu">Interface</a>|
														]
													),
													(	qq|Logs|,
														[	qq|<a id='nmislogs' href="logs.pl?conf=$Q->{conf}&amp;act=log_file_view&amp;logname=NMIS_Log">NMIS Log</a>|,
															qq|<a id='nmislogs' href="logs.pl?conf=$Q->{conf}&amp;act=log_file_view&amp;logname=Event_Log">Event Log</a>|,
															qq|<a id='nmislogs' href="logs.pl?conf=$Q->{conf}&amp;act=log_list_view">Log List</a>|
														]
													)
												]
											);
											
											
		push @menu_site,(	qq|System|,
											[
												( qq|System Configuration|,
													[	
														qq|<a id='cfg_access' href="tables.pl?conf=$Q->{conf}&amp;act=config_table_menu&amp;table=Access">Access</a>|,
														qq|<a id='cfg_businessservices' href="tables.pl?conf=$Q->{conf}&amp;act=config_table_menu&amp;table=BusinessServices">Business Services</a>|,
														qq|<a id='cfg_cmdbmodels' href="tables.pl?conf=$Q->{conf}&amp;act=config_table_menu&amp;table=cmdbModels">CMDB Models</a>|,
														qq|<a id='cfg_contacts' href="tables.pl?conf=$Q->{conf}&amp;act=config_table_menu&amp;table=Contacts">Contacts</a>|,
														qq|<a id='cfg_escalations' href="tables.pl?conf=$Q->{conf}&amp;act=config_table_menu&amp;table=Escalations">Escalations</a>|,
														qq|<a id='cfg_iftypes' href="tables.pl?conf=$Q->{conf}&amp;act=config_table_menu&amp;table=ifTypes">ifTypes</a>|,
														qq|<a id='cfg_locations' href="tables.pl?conf=$Q->{conf}&amp;act=config_table_menu&amp;table=Locations">Locations</a>|,
														qq|<a id='cfg_logs' href="tables.pl?conf=$Q->{conf}&amp;act=config_table_menu&amp;table=Logs">Logs</a>|,
														qq|<a id='cfg_models' href="models.pl?conf=$Q->{conf}&amp;act=config_model_menu">Models</a>|,
														qq|<a id='cfg_nmis' href="config.pl?conf=$Q->{conf}&amp;act=config_nmis_menu">NMIS Configuration</a>|,
														qq|<a id='cfg_nodecfg' href="nodeconf.pl?conf=$Q->{conf}&amp;act=config_nodeconf_view">Node Configuration</a>|,
														qq|<a id='cfg_nodes' href="tables.pl?conf=$Q->{conf}&amp;act=config_table_menu&amp;table=Nodes">Nodes (devices)</a>|,
														qq|<a id='cfg_portal' href="tables.pl?conf=$Q->{conf}&amp;act=config_table_menu&amp;table=Portal">Portal</a>|,
														qq|<a id='cfg_privmap' href="tables.pl?conf=$Q->{conf}&amp;act=config_table_menu&amp;table=PrivMap">PrivMap</a>|,
														qq|<a id='cfg_services' href="tables.pl?conf=$Q->{conf}&amp;act=config_table_menu&amp;table=Services">Services</a>|,
														qq|<a id='cfg_servicestatus' href="tables.pl?conf=$Q->{conf}&amp;act=config_table_menu&amp;table=ServiceStatus">Service Status</a>|,
														qq|<a id='cfg_users' href="tables.pl?conf=$Q->{conf}&amp;act=config_table_menu&amp;table=Users">Users</a>|,
													]
												),
												( qq|Configuration Check|,
													[	qq|<a id='tls_event_flow' href="view-event.pl?conf=$Q->{conf}&amp;act=event_flow_view">Check Event Flow</a>|,
														qq|<a id='tls_event_db' href="view-event.pl?conf=$Q->{conf}&amp;act=event_database_list">Check Event DB</a>|
													]
												),
												( qq|Host Diagnostics|,
													[
														qq|<a id='nmis_poll' href="network.pl?conf=$Q->{conf}&amp;act=nmis_polling_summary">NMIS Polling Summary</a>|,
														qq|<a id='nmis_run' href="network.pl?conf=$Q->{conf}&amp;refresh=$widget_refresh&amp;act=nmis_runtime_view">NMIS Runtime Graph</a>|,
														qq|<a id='tls_host_info' href="tools.pl?conf=$Q->{conf}&amp;act=tool_system_hostinfo">NMIS Host Info</a>|,
														qq|<a id='tls_date' href="tools.pl?conf=$Q->{conf}&amp;act=tool_system_date">date</a>|,
														qq|<a id='tls_df' href="tools.pl?conf=$Q->{conf}&amp;act=tool_system_df">df</a>|,
														qq|<a id='tls_ps' href="tools.pl?conf=$Q->{conf}&amp;act=tool_system_ps">ps</a>|,
														qq|<a id='tls_iostat' href="tools.pl?conf=$Q->{conf}&amp;act=tool_system_iostat">iostat</a>|,
														qq|<a id='tls_vmstat' href="tools.pl?conf=$Q->{conf}&amp;act=tool_system_vmstat">vmstat</a>|,
														qq|<a id='tls_who' href="tools.pl?conf=$Q->{conf}&amp;act=tool_system_who">who</a>|
													]
												)
											]
										);
										
		push @menu_site,( qq|Quick Select|,
												[	qq|<a id='selectServer_open' onclick="selectServerDisplay();return false;">NMIS Server</a>|,
													qq|<a id='selectNode_open' onclick="selectNodeOpen();return false;">Quick Search</a>|
												]
										);

		push @menu_site,( qq|Windows|,
												[	qq|<a id='saveWindow_open' onclick="saveWindowState();return false;">Save Windows and Positions</a>|,
													qq|<a id='clearWindow_open' onclick="clearWindowState();return false;">Clear Windows and Positions</a>|
												]
										);

		push @menu_site,( qq|Help|,
												[	qq|<a id='hlp_help' target='_blank' href="http://www.opmantek.com">NMIS</a>|,
													qq|<a id='hlp_apache' target='_blank' href="http://www.apache.org" id='apache'>Apache</a>|,
													qq|<a id='hlp_about' href="menu.pl?conf=$Q->{conf}&amp;act=menu_about_view">About</a>|
												]
										);
		return \@menu_site;
	}
}
	#==============================

# HORIZANTAL Menu - home and client tags

sub menu_bar_portal {
	
	# take this to config.nmis.!
	# portal menu of nodes or clients to link to.
	
	print header({-type=>"text/html",-expires=>'now'});
	print		$q->start_ul({ class=>"jd_menu"});
	print_array_list( menu_portal(), 1 , 0 );
	print $q->end_ul();


	sub menu_portal {
		my @menu_portal = [];
				push @menu_portal,	( qq|<a href="nmiscgi.pl?conf=$Q->{conf}" target='_self'>NMIS8 Home</a>|);
				push @menu_portal,	( qq|Client Views|,
												[
												 qq|<a href="http://master.nmis.co.nz/cgi-master/nmiscgi.pl" target='_blank'>NMIS4 Demo Master/Slave</a>|,
												  qq|<a href="#" >Customer A</a>|,
												   qq|<a href="#" >Customer B</a>|
												   
												]);
				
		return [ @menu_portal ];
	}
}

# ADD Node panel on request

sub menu_panel_node {
	# popup the next panels, include the 'nodename' and submenu of that.
	print header({-type=>"text/html",-expires=>'now'});
	print		$q->start_ul({ class=>"jd_menu jd_menu_vertical"});
	print_array_list( [( $Q->{node} , menu_node_panel(node=>$Q->{node}) )], 1, 1 );
	print $q->end_ul();
}

#==============================

# CREATE Node panel (for nodeselect links)
# this is a <ul><li> .... </li></ul>

sub menu_node_panel {
	my %args = @_;
	my $node = $args{node};
	my $if;
	my $tooltip;

	my $NI = loadNodeInfoTable($node);
	my @menuInt;
	my @tmp;
	push @menuInt,	( qq|<a id="panel" name="Node" href="network.pl?conf=$Q->{conf}&amp;act=network_node_view&amp;node=$node&amp;server=$C->{server}">Node</a>| );
	# added check for no interfaces, node is down or never collected due to snmp fault..
	if ($NI->{system}{collect} eq 'true' and keys %{$NI->{interface}} ) {
		#$menu_site[1][0] = qq|<a Interfaces</a>|;
		# check for interface up and collect is true
		# create temporal table
		foreach my $intf (keys %{$NI->{interface}}) {
			# get all interface where oper is up and collecting
			if ($NI->{interface}{$intf}{ifAdminStatus} eq 'up' and $NI->{interface}{$intf}{collect} eq 'true') {
				$if->{$intf}{ifDescr} = $NI->{interface}{$intf}{ifDescr};
				$if->{$intf}{Description} = $NI->{interface}{$intf}{Description};
			}
		}
		@tmp=();
		# create the sorted interface list
		# but only if interface info available
		foreach my $intf (sorthash($if,['ifDescr'],'fwd')) {

			#TBD - nmisdev - replace with jquery popup ??

			$tooltip = '';
			#	$tooltip = ($if->{$intf}{Description} ne '' and $if->{$intf}{Description} ne 'noSuchObject') ? $if->{$intf}{Description} : '';
			#	$tooltip =~ s{[&<>/"']}{}g;  # needs work - fails ?
	
			if ($tooltip ne '') {
				push @tmp, (
						qq|<a id="panel" name="$if->{$intf}{ifDescr}" href="network.pl?conf=$Q->{conf}&amp;act=network_interface_view&amp;node=$node&amp;intf=$intf&amp;server=$C->{server}">$if->{$intf}{ifDescr}</a>|,
					,
					[ qq|<a id="panel" name="$if->{$intf}{ifDescr}_tp" title="$tooltip" href="network.pl?conf=$Q->{conf}&amp;act=network_interface_view&amp;node=$node&amp;intf=$intf&amp;server=$C->{server}">$tooltip</a>|
					]);
			} else {
				push @tmp, (  qq|<a id="panel" name="$if->{$intf}{ifDescr}" href="network.pl?conf=$Q->{conf}&amp;act=network_interface_view&amp;node=$node&amp;intf=$intf&amp;server=$C->{server}">$if->{$intf}{ifDescr}</a>| );
			}
		} # end int by int
		push @menuInt, ( 'Interfaces', [@tmp] );
		push  @menuInt, (  qq|<a id="panel" name="All Interfaces" href="network.pl?conf=$Q->{conf}&amp;act=network_interface_view_all&amp;node=$node">All interfaces</a>|);
		push  @menuInt, (  qq|<a id="panel" name="Active Interfaces" href="network.pl?conf=$Q->{conf}&amp;act=network_interface_view_act&amp;node=$node&amp;server=$C->{server}">Active Interfaces</a>|);
		if ($NI->{system}{nodeType} =~ /router|switch/ ) {
			push  @menuInt, (  qq|<a id="panel" name="Port Stats" href="network.pl?conf=$Q->{conf}&amp;act=network_port_view&amp;node=$node&amp;server=$C->{server}">Port Stats</a>|);
		}
		if ($NI->{system}{nodeType} =~ /server/ ) {
			push  @menuInt, ( qq|<a id="panel" name="Storage" href="network.pl?conf=$Q->{conf}&amp;act=network_storage_view&amp;node=$node&amp;server=$C->{server}">Storage</a>|);
		}
	}

	push  @menuInt, (  qq|<a id="panel" name="Events" href="events.pl?conf=$Q->{conf}&amp;act=event_table_view&amp;node=$node&amp;server=$C->{server}">Events</a>|);
	push  @menuInt, (  qq|<a id="panel" name="Outage" href="outages.pl?conf=$Q->{conf}&amp;act=outage_table_view&amp;node=$node&amp;server=$C->{server}">Outage</a>|);
	push  @menuInt, (  qq|Tools|,
							[
	 							qq|<a id="panel" name="Telnet" href="telnet://$NI->{system}{host}">Telnet</a>|,
								qq|<a id="panel" name="Ping" href="tools.pl?conf=$Q->{conf}&amp;act=tool_system_ping&amp;node=$node&amp;server=$C->{server}">Ping</a>|,
								qq|<a id="panel" name="Trace" href="tools.pl?conf=$Q->{conf}&amp;act=tool_system_trace&amp;node=$node&amp;server=$C->{server}">Trace</a>|
							]);
	return [ @menuInt ];			# return all
	
}


#==============================

sub menu_about_view {
	print header({-type=>"text/html",-expires=>'now'});
	print table(Tr(td({class=>'info'},<<EO_TEXT)));
<br/>
Network Management Information System<br/>
NMIS Version $NMIS::VERSION<br/>
Copyright (C) 1999-2011 <a href="http://www.opmantek.com">Opmantek Limited (www.opmantek.com)</a><br/>
This program comes with ABSOLUTELY NO WARRANTY;<br/>
This is free software licensed under GNU GPL, and you are welcome to<br/>
redistribute it under certain conditions; see <a href="http://www.opmantek.com">www.opmantek.com</a> or email<br/>
 <a href="mailto://contact@opmantek.com">contact\@opmantek.com<br/>

EO_TEXT

}

sub save_window_state {
	my $data = $Q->{POSTDATA};	
	my $windowData = from_json($data);	
	my $userWindowData = { $user => $windowData->{windowData} };
	
	writeTable(dir=>'conf',name=>"WindowState",data=>$userWindowData);

	print header({-type=>"text/html",-expires=>'now'});
	print table(Tr(td({class=>'info'},<<EO_TEXT)));
<br/>
Success
EO_TEXT
	return;
}
# *****************************************************************************
# NMIS Copyright (C) 1999-2011 Opmantek Limited (www.opmantek.com)
# This program comes with ABSOLUTELY NO WARRANTY;
# This is free software licensed under GNU GPL, and you are welcome to 
# redistribute it under certain conditions; see www.opmantek.com or email
# contact@opmantek.com
# *****************************************************************************
