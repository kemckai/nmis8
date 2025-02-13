#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#
#  ALL CODE MODIFICATIONS MUST BE SENT TO CODE@OPMANTEK.COM
#
#  This file is part of Network Management Information System (“NMIS”).
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
package NMIS;
our $VERSION = "8.7.2G";

use NMIS::uselib;
use lib "$NMIS::uselib::rrdtool_lib";

use strict;
use RRDs;
use Time::Local;
use DateTime;
use Net::hostent;
use Socket 2.001;								# for getnameinfo() used by resolveDNStoAddr
use func;
use csv;
use notify;
use ip;
use Sys;
use DBfunc;
use URI::Escape;
use JSON::XS 2.01;
use File::Basename;
use File::Copy;
use Clone;
use List::Util 1.33;
use CGI qw();												# very ugly but createhrbuttons needs it :(
use NMIS::UUID;
use Digest::MD5;								# for htmlGraph, nothing stronger is needed
use NMIS::RRDdraw;							# for htmlGraph

#! Imports the LOCK_ *constants (eg. LOCK_UN, LOCK_EX)
use Fcntl qw(:DEFAULT :flock);

use Data::Dumper;
$Data::Dumper::Indent = 1;

use vars qw(@ISA @EXPORT);
use Exporter;

@ISA = qw(Exporter);

@EXPORT = qw(
		loadLinkDetails
		loadNodeTable
		loadLocalNodeTable
		loadNodeSummary
		loadNodeInfoTable
		loadGroupTable
		loadGenericTable
		tableExists
		loadContactsTable
		loadLocationsTable
		loadEscalationsTable
		loadifTypesTable
		loadServicesTable
    loadServiceStatus
    saveServiceStatus
		loadUsersTable
		loadPrivMapTable
		loadAccessTable
		loadLinksTable
		loadRMENodes
		loadServersTable
		loadWindowStateTable

		loadInterfaceInfo
		loadInterfaceInfoShort
		loadEnterpriseTable

		loadNodeConfTable has_nodeconf get_nodeconf update_nodeconf

		loadInterfaceTypes
		loadCfgTable
		findCfgEntry

		checkNodeName
		isNodeCollectable

		eventLevel
		eventExist
    eventLoad eventAdd eventUpdate eventDelete
		cleanEvent loadAllEvents
		logEvent
		eventAck
		checkEvent
		notify

    outageCheck

		nodeStatus
    PreciseNodeStatus

		getSummaryStats
		getGroupSummary
		getNodeSummary
		getLevelLogEvent
		overallNodeStatus
		getOperColor
		getAdminColor
		colorHighGood
		colorPort
		colorLowGood
		colorResponseTimeStatic
		thresholdPolicy
		thresholdResponse
		thresholdLowPercent
		thresholdHighPercent
		thresholdHighPercentLoose
		thresholdMemory
		thresholdInterfaceUtil
		thresholdInterfaceAvail
		thresholdInterfaceNonUnicast

		convertConfFiles
		statusNumber
		logMessage

		eventToSMTPPri
		dutyTime
		resolveDNStoAddr
		htmlGraph
		createHrButtons
		loadPortalCode
		loadServerCode
		loadTenantCode

		startNmisPage
		pageStart
		pageStartJscript
		getJavaScript
		pageEnd

		requestServer
	);

# Cache table pointers
my $NT_cache = undef; # node table (local + remote)
my $NT_modtime; # file modification time
my $LNT_cache = undef; # local node table
my $LNT_modtime;
my $GT_cache = undef; # group table
my $GT_modtime;
my $ST_cache = undef; # server table
my $ST_modtime;

my $SUM8_cache = undef; # summary table
my $SUM8_modtime;
my $SUM16_cache = undef; # summary table
my $SUM16_modtime;
my $ENT_cache = undef; # enterprise table
my $ENT_modtime;
my $IFT_cache = undef; # ifTypes table
my $IFT_modtime;
my $SRC_cache = undef; # Services table
my $SRC_modtime;

# preset kernel name
my $kernel = $^O;

sub loadLinkDetails {
	my $C = loadConfTable();
	my %linkTable = &loadCSV($C->{Links_Table},$C->{Links_Key},"\t");
	return \%linkTable;
} #sub loadLinkDetails


# load local node table
#
# optionally sanitises nodes data:
# nodes that lack critical properties are removed
#
# args: sanitise (optional, default: 0)
# returns: hash ref
sub loadLocalNodeTable
{
	my (%args) = @_;

	my $C = loadConfTable();			# usually cached

	my $lotsanodes = getbool($C->{db_nodes_sql})?
			DBfunc::->select(table=>'Nodes')
			: loadTable(dir=>'conf',name=>'Nodes');

	return $lotsanodes if (!$args{sanitise});

	my $badones;
	# deemed critical: name, uuid, host, group properties
	my @musthave = qw(name uuid host group);
	# also deemed critical: node name must match the rules
	my $nodenamerule = $C->{node_name_rule} || qr/^[a-zA-Z0-9_. -]+$/;

	for my $maybebad (keys %$lotsanodes)
	{
		my $noderec = $lotsanodes->{$maybebad};
		my $because;

		if (ref($noderec) ne "HASH")
		{
			$because = "invalid structure";
		}
		elsif (List::Util::any { !defined($noderec->{$_}) or $noderec->{$_} eq '' } (@musthave))
		{
			$because = "some required properties are missing";
		}
		elsif (lc($noderec->{name}) ne lc($maybebad))
		{
			$because = "invalid structure, name and key don't match";
		}
		elsif ($noderec->{name} !~ $nodenamerule)
		{
			$because = "node name is invalid, does not match 'node_name_rule' regexp";
		}

		if ($because)
		{
			++$badones;
			delete $lotsanodes->{$maybebad};
			# this is bad enough to justify stderr/cron noise...
			my $msg = "WARNING: deleting invalid Node record for \"$maybebad\": $because";
			logMsg($msg);
			warn("$msg\n");
		}
	}
	if ($badones)
	{
		writeHashtoFile(file => "$C->{'<nmis_conf>'}/Nodes", data => $lotsanodes);
	}
	return $lotsanodes;
}

sub loadNodeTable {

	my $reload = 'false';

	my $C = loadConfTable();

	if (getbool($C->{server_master})) {
		# check modify of remote node tables
		my $ST = loadServersTable();
		for my $srv (keys %{$ST}) {
			## don't process server localhost for opHA2
			next if $srv eq "localhost";

			my $name = "nmis-${srv}-Nodes";
			if (! loadTable(dir=>'var',name=>$name,check=>'true') ) {
				$reload = 'true';
			}
		}
	}

	if (not defined $NT_cache or ( mtimeFile(dir=>'conf',name=>'Nodes') ne $NT_modtime) ) {
		$reload = 'true';
	}

	return $NT_cache if getbool($reload,"invert");

	# rebuild tables
	$NT_cache = undef;
	$GT_cache = undef;

	my $LNT = loadLocalNodeTable();
	my $master_server_priority = $C->{master_server_priority} || 10;

	foreach my $node (keys %{$LNT}) {
		$NT_cache->{$node}{server} = $C->{server_name};
		### set the default server priority to 10 as local node
		$NT_cache->{$node}{server_priority} = $master_server_priority;
		foreach my $k (keys %{$LNT->{$node}} ) {
			$NT_cache->{$node}{$k} = $LNT->{$node}{$k};
		}
		if ( getbool($LNT->{$node}{active})) {
			$GT_cache->{$LNT->{$node}{group}} = $LNT->{$node}{group};
		}
	}
	$NT_modtime = mtimeFile(dir=>'conf',name=>'Nodes');

	if (getbool($C->{server_master})) {
		# check modify of remote node tables
		my $ST = loadServersTable();
		my $NT;
		for my $srv (keys %{$ST}) {
			## don't process server localhost for opHA2
			next if $srv eq "localhost";

			# Relies on nmis.pl getting the file every 5 minutes.
			my $name = "nmis-${srv}-Nodes";
			my $server_priority = $ST->{$srv}{server_priority} || 5;

			if (($NT = loadTable(dir=>'var',name=>$name)) ) {
				foreach my $node (keys %{$NT}) {
					$NT->{$node}{server} = $srv ;
					$NT->{$node}{server_priority} = $server_priority ;
					if (
						( not defined $NT_cache->{$node}{name} and $NT_cache->{$node}{name} eq "" )
						or
						( defined $NT_cache->{$node}{name} and $NT_cache->{$node}{name} ne "" and $NT->{$node}{server_priority}  > $NT_cache->{$node}{server_priority} )
					) {
						foreach my $k (keys %{$NT->{$node}} ) {
							$NT_cache->{$node}{$k} = $NT->{$node}{$k};
						}
						if ( getbool($NT->{$node}{active})) {
							$GT_cache->{$NT->{$node}{group}} = $NT->{$node}{group};
						}
					}
				}
			}
		}
	}
	return $NT_cache;
}

# returns a hash of groupname => groupname,
# with all groups that were observed configured for active nodes
# note: does NOT filter by group_list from the configuration!
sub loadGroupTable
{
	if (not defined $GT_cache
			or not defined $NT_cache
			or ( mtimeFile(dir=>'conf',name=>'Nodes') ne $NT_modtime) )
	{
		loadNodeTable();
	}

	return $GT_cache;
}

sub tableExists {
	my $table = shift;
	my $exists = 0;

	if (existFile(dir=>"conf",name=>$table)) {
		$exists = 1;
	}

	return $exists;
}

sub loadFileOrDBTable {
	my $table = shift;
	my $ltable = lc $table;

	my $C = loadConfTable();
	if (getbool($C->{"db_${ltable}_sql"})) {
		return DBfunc::->select(table=>$table);
	} else {
		return loadTable(dir=>'conf',name=>$table);
	}
}

sub loadGenericTable{
	return loadFileOrDBTable( shift );
}

sub loadContactsTable {
	return loadFileOrDBTable('Contacts');
}

sub loadAccessTable {
	return loadFileOrDBTable('Access');
}

sub loadPrivMapTable {
	return loadFileOrDBTable('PrivMap');
}

sub loadUsersTable {
	return loadFileOrDBTable('Users');
}

sub loadLocationsTable {
	return loadFileOrDBTable('Locations');
}

sub loadifTypesTable {
	return loadFileOrDBTable('ifTypes');
}

sub loadServicesTable {
	return loadFileOrDBTable('Services');
}

sub loadLinksTable {
	return loadTable(dir=>'conf',name=>'Links');
}

sub loadEscalationsTable {
	return loadFileOrDBTable('Escalations');
}

sub loadWindowStateTable
{
	my $C = loadConfTable();

	return {} if (not -r getFileName(file => "$C->{'<nmis_var>'}/nmis-windowstate"));
	return loadTable(dir=>'var',name=>'nmis-windowstate');
}

# az [2018-08-09 Thu 11:47] deprecated DO NOT USE!
# check node name case insentive, return good one
sub checkNodeName {
	my $name = shift;
	my $NT;

	if ($NT = loadLocalNodeTable()) {
		foreach my $nm (keys %{$NT}) {
			if (lc $name eq lc $nm) {
				# found
				return $nm;
			}
		}
		logMsg("ERROR (nmis) node=$name does not exists in table Nodes");
	}
	return;
}

#==================================================================

# this small helper looks for a display/validation rule entry in a table-xyz datastructure
# and returns the structure info for that item
# args: item name (required),
# section (optional, if not given all sections are trawled)
# table (optional live structure, if not given the Config table is loaded)
#
# returns: hashref (keys display, value etc.) or undef if not found
sub findCfgEntry
{
	my (%args) = @_;
	my ($section,$item, $meta) = @args{qw(section item table)};

	$meta ||= loadCfgTable();
	for my $maybesection (defined $section? ($section) : sort keys %$meta)
	{
		for my $entry (@{$meta->{$maybesection}})
		{
			if (exists($entry->{$item}))
			{
				return $entry->{$item};
			}
		}
	}
	return undef;
}

# this loads a Table-<sometable> config structure (for the gui)
# and returns the <sometable> substructure - outermost is always hash,
# substructure is usually an array (except for Table-Config, which is one level deeper)
#
# args: table name (e.g. Nodes), defaults to "Config",
# user (optional, if given will be set in %ENV for any dynamic tables that need it)
#
# returns: (array or hash)ref or undef on error
sub loadCfgTable
{
	my %args = @_;

	my $tablename = $args{table} || "Config";

	# some tables contain complex code, call auth methods  etc,
	# and need to know who the originator is
	my $oldcontext = $ENV{"NMIS_USER"};
	if (my $usercontext = $args{user})
	{
		$ENV{"NMIS_USER"} = $usercontext;
	}
	my $goodies = loadGenericTable("Table-$tablename");
	$ENV{"NMIS_USER"} = $oldcontext; # let's not leave a mess behind.

	if (ref($goodies) ne "HASH" or !keys %$goodies)
	{
		logMsg("ERROR, failed to load Table-$tablename");
		return undef;
	}
	return $goodies->{$tablename};
}

sub loadRMENodes {

	my $file = shift;

	my %nodeTable;

	my $C = loadConfTable();

	my $ciscoHeader = "Cisco Systems NM";
	my @nodedetails;
	my @statsSplit;
	my $nodeType;

	if ( $file eq "" ) {
		print "\t the type=rme option requires a file arguement for source rme CSV file\ni.e. $0 type=rme rmefile=/data/file/rme.csv\n";
		return;
	}

	sysopen(DATAFILE, "$file", O_RDONLY) or warn returnTime." loadRMENodes, Cannot open $file. $!\n";
	flock(DATAFILE, LOCK_SH) or warn "loadRMENodes, can't lock filename: $!";
	while (<DATAFILE>) {
	        chomp;
		# Don't want comments
	        if ( $_ !~ /^\;|^$ciscoHeader/ ) {
			# whack all the splits into an array
			(@nodedetails) = split ",", $_;

			# check that the device is to be included in STATS
			$nodedetails[4] =~ s/ //g;
			@statsSplit = split(":",$nodedetails[4]);
			if ( $statsSplit[0] =~ /t/ ) {
				# sopme defaults
				$nodeTable{$nodedetails[0]}{depend} = "N/A";
				$nodeTable{$nodedetails[0]}{runupdate} = "false";
				$nodeTable{$nodedetails[0]}{snmpport} = "161";
				$nodeTable{$nodedetails[0]}{active} = "true";
				$nodeTable{$nodedetails[0]}{group} = "RME";

				$nodeTable{$nodedetails[0]}{host} = $nodedetails[0];
				$nodeTable{$nodedetails[0]}{community} = $nodedetails[1];
				$nodeTable{$nodedetails[0]}{netType} = $statsSplit[1];
				$nodeTable{$nodedetails[0]}{nodeType} = $statsSplit[2];
				# Convert role c, d or a to core, distribution or access (or default)
				if ( $statsSplit[3] eq "c" ) { $nodeTable{$nodedetails[0]}{roleType} = "core"; }
				elsif ( $statsSplit[3] eq "d" ) { $nodeTable{$nodedetails[0]}{roleType} = "distribution"; }
				elsif ( $statsSplit[3] eq "a" ) { $nodeTable{$nodedetails[0]}{roleType} = "access"; }
				else
				{
					$nodeTable{$nodedetails[0]}{roleType} = "default";
				}
				# Convert collect t or f to  true or false
				if ( $statsSplit[4] eq "t" ) { $nodeTable{$nodedetails[0]}{collect} = "true"; }
				elsif ( $statsSplit[4] eq "f" ) { $nodeTable{$nodedetails[0]}{collect} = "false"; }
			}
		}
	}
	close(DATAFILE) or warn "loadRMENodes, can't close filename: $!";
	writeNodesFile("$C->{Nodes_Table}.new",\%nodeTable);
}

# load servers info table
sub loadServersTable {
	return loadTable(dir=>'conf',name=>'Servers');
}

### 2011-01-06 keiths, loading node summary from cached files!
sub loadNodeSummary {
	my %args = @_;
	my $group = $args{group};
	my $master = $args{master};

	my $C = loadConfTable();
	my $SUM;

	my $nodesum = "nmis-nodesum";

	# logically if I am a standalone server or I am a master I can use this.
	my $master_server_priority = $C->{master_server_priority} || 1;

	# I should now have an up to date file, if I don't log a message
	if (existFile(dir=>'var',name=>$nodesum) ) {
		dbg("Loading $nodesum");
		my $NS = loadTable(dir=>'var',name=>$nodesum);
		for my $node (keys %{$NS}) {
			if ( $group eq "" or $group eq $NS->{$node}{group} ) {
				for (keys %{$NS->{$node}}) {
					$SUM->{$node}{$_} = $NS->{$node}{$_};
				}
				if ( not defined $SUM->{$node}{server_priority} ) {
					$SUM->{$node}{server_priority} = $master_server_priority;
				}
			}
		}
	}

	### 2011-12-29 keiths, moving master handling outside of Cache handling!
	if (getbool($C->{server_master}) or getbool($master)) {
		dbg("Master, processing Slave Servers");
		my $ST = loadServersTable();
		for my $srv (keys %{$ST}) {
			## don't process server localhost for opHA2
			next if $srv eq "localhost";

			my $server_priority = $ST->{$srv}{server_priority} || 5;

			my $slavenodesum = "nmis-$srv-nodesum";
			dbg("Processing Slave $srv for $slavenodesum");
			# I should now have an up to date file, if I don't log a message
			if (existFile(dir=>'var',name=>$slavenodesum) ) {
				my $NS = loadTable(dir=>'var',name=>$slavenodesum);
				for my $node (keys %{$NS}) {
					if ( $group eq "" or $group eq $NS->{$node}{group} ) {
						if ( not exists $SUM->{$node}
								or $SUM->{$node}{server} eq $srv
								or ( exists $SUM->{$node}
									and $SUM->{$node}{server_priority}
									and $SUM->{$node}{server_priority} < $server_priority
									)
						) {
							for (keys %{$NS->{$node}}) {
								$SUM->{$node}{$_} = $NS->{$node}{$_};
							}
							$SUM->{$node}{server_priority} = $server_priority;
							$SUM->{$node}{server} = $srv;
						}
					}
				}
			}
		}
	}
	return $SUM;
}

# this is the most official reporter of node status, and should be
# used instead of just looking at local system info nodedown
#
# reason for looking for events (instead of wmidown/snmpdown markers):
# underlying events state can change asynchronously (eg. fpingd), and the per-node status from the node
# file cannot be guaranteed to be up to date if that happens.
sub nodeStatus {
	my %args = @_;
	my $NI = $args{NI};
	my $C = loadConfTable();

	# 1 for reachable
	# 0 for unreachable
	# -1 for degraded
	my $status = 1;

	my $node_down = "Node Down";
	my $snmp_down = "SNMP Down";
	my $wmi_down_event = "WMI Down";
	my $failover_event = "Node Polling Failover";

	# ping disabled -> the WORSE one of snmp and wmi states is authoritative
	if (getbool($NI->{system}{ping},"invert")
			 and ( eventExist($NI->{system}{name}, $snmp_down, "")
						 or eventExist($NI->{system}{name}, $wmi_down_event, "")))
	{
		$status = 0;
	}
	# ping enabled, but unpingable -> down
	elsif ( eventExist($NI->{system}{name}, $node_down, "") ) {
		$status = 0;
	}
	# ping enabled, pingable but dead snmp or dead wmi or failover'd -> degraded
	# only applicable is collect eq true, handles SNMP Down incorrectness
	elsif ( getbool($NI->{system}{collect}) and
					( eventExist($NI->{system}{name}, $snmp_down, "")
						or eventExist($NI->{system}{name}, $wmi_down_event, "")
						or eventExist($NI->{system}{name}, $failover_event, "")
					))
	{
		$status = -1;
	}
	# let NMIS use the status summary calculations
	elsif (
		defined $C->{node_status_uses_status_summary}
		and getbool($C->{node_status_uses_status_summary})
		and defined $NI->{system}{status_summary}
		and defined $NI->{system}{status_updated}
		and $NI->{system}{status_summary} <= 99
		and $NI->{system}{status_updated} > time - 500
	) {
		$status = -1;
	}
	else {
		$status = 1;
	}

	return $status;
}

# this is a variation of nodeStatus, which doesn't say why a node is degraded
# args: system object (doesn't have to be init'd with snmp/wmi)
# returns: hash of error (if dud args),
#  overall (-1 deg, 0 down, 1 up),
#  snmp_enabled (0,1), snmp_status (0,1,undef if unknown),
#  ping_enabled and ping_status (note: ping status is 1 if primary or backup address are up)
#  wmi_enabled and wmi_status,
#  failover_status (0 failover, 1 ok, undef if unknown/irrelevant)
#  failover_ping_status (0 backup host is down, 1 ok, undef if irrelevant)
#  primary_ping_status (0 primary host is down, 1 ok, undef if irrelevant)
sub PreciseNodeStatus
{
	my (%args) = @_;
	my $S = $args{system};
	return ( error => "Invalid arguments, no Sys object!" ) if (ref($S) ne "Sys");

	my $C = loadConfTable();

	my $nisys = $S->ndinfo->{system};
	my $nodename = $nisys->{name};

	# reason for looking for events (instead of wmidown/snmpdown markers):
	# underlying events state can change asynchronously (eg. fpingd), and the per-node status from the node
	# file cannot be guaranteed to be up to date if that happens.

	# HOWEVER the markers snmpdown and wmidown are present iff the source was enabled at the last collect,
	# and if collect was true as well.
	my %precise = ( overall => 1, # 1 reachable, 0 unreachable, -1 degraded
									snmp_enabled =>  defined($nisys->{snmpdown})||0,
									wmi_enabled => defined($nisys->{wmidown})||0,
									ping_enabled => getbool($nisys->{ping}),
									snmp_status => undef,
									wmi_status => undef,
									ping_status => undef,
									failover_status => undef, # 1 ok, 0 in failover, undef if unknown/irrelevant
									failover_ping_status => undef, # 1 backup host is pingable, 0 not, undef unknown/irrelevant
									primary_ping_status => undef,
			);

	my $downexists = eventExist($nodename, "Node Down");
	my $failoverexists = eventExist($nodename, "Node Polling Failover");
	my $backupexists = eventExist($nodename, "Backup Host Down");

	$precise{ping_status} = ($downexists? 0:1) if ($precise{ping_enabled}); # otherwise we don't care
	$precise{wmi_status} = (eventExist($nodename, "WMI Down")?0:1) if ($precise{wmi_enabled});
	$precise{snmp_status} = (eventExist($nodename, "SNMP Down")?0:1) if ($precise{snmp_enabled});

	if ($nisys->{host_backup})		# s->ndcfg is not populated if sys::init was called with snmp/wmi false :-(
	{
		$precise{failover_status} = $failoverexists? 0:1;
			$precise{primary_ping_status} = ($downexists || $failoverexists)? 0:1; # the primary is dead if all are dead or if we failed-over
		$precise{failover_ping_status} = ($backupexists || $downexists)? 0:1; # the secondary is dead if known to be dead or if all are dead
	}

	# overall status: ping disabled -> the WORSE one of snmp and wmi states is authoritative
	if (!$precise{ping_enabled}
			and ( ($precise{wmi_enabled} and !$precise{wmi_status})
						or ($precise{snmp_enabled} and !$precise{snmp_status}) ))
	{
		$precise{overall} = 0;
	}
	# ping enabled, but unpingable -> unreachable
	elsif ($precise{ping_enabled} && !$precise{ping_status} )
	{
		$precise{overall} = 0;
	}
	# ping enabled, pingable but dead snmp or dead wmi or failover -> degraded
	# only applicable is collect eq true, handles SNMP Down incorrectness
	elsif ( ($precise{wmi_enabled} and !$precise{wmi_status})
					or ($precise{snmp_enabled} and !$precise{snmp_status})
					or (defined($precise{failover_status}) && !$precise{failover_status})
					or (defined($precise{failover_ping_status}) && !$precise{failover_ping_status})
			)
	{
		$precise{overall} = -1;
	}
	# let NMIS use the status summary calculations, if recently updated
	elsif ( defined $C->{node_status_uses_status_summary}
					and getbool($C->{node_status_uses_status_summary})
					and defined $nisys->{status_summary}
					and defined $nisys->{status_updated}
					and $nisys->{status_summary} <= 99
					and $nisys->{status_updated} > time - 500 )
	{
		$precise{overall} = -1;
	}
	else
	{
		$precise{overall} = 1;
	}
	return %precise;
}

sub logConfigEvent {
	my %args = @_;
	my $dir = $args{dir};
	delete $args{dir};

	dbg("logConfigEvent logging Json event for event $args{event}");
	my $event_hash = \%args;
	$event_hash->{startdate} = time;
	logJsonEvent(event => $event_hash, dir => $dir);
}

sub getLevelLogEvent {
	my %args = @_;
	my $S = $args{sys};
	my $NI = $S->ndinfo;
	my $M = $S->mdl;
	my $event = $args{event};
	my $level = $args{level};

	my $mdl_level;
	# set the default policy to true
	my $log = 'true';
	my $syslog = 'true';
	my $pol_event;

	my $role = $NI->{system}{roleType} || 'access' ;
	my $type = $NI->{system}{nodeType} || 'router' ;

	# Get the event policy and the rest is easy.
	if ( $event !~ /^Proactive|^Alert/i ) {
		# proactive does already level defined
		if ( $event =~ /down/i and $event !~ /SNMP|Node|Interface|Service/i ) {
			$pol_event = "Generic Down";
		}
		elsif ( $event =~ /up/i and $event !~ /SNMP|Node|Interface|Service/i ) {
			$pol_event = "Generic Up";
		}
		else { $pol_event = $event; }

		# get the level and log from Model of this node
		if ($mdl_level = $M->{event}{event}{lc $pol_event}{lc $role}{level}) {
			$log = $M->{event}{event}{lc $pol_event}{lc $role}{logging};
			$syslog = $M->{event}{event}{lc $pol_event}{lc $role}{syslog} if ($M->{event}{event}{lc $pol_event}{lc $role}{syslog} ne "");
		}
		elsif ($mdl_level = $M->{event}{event}{default}{lc $role}{level}) {
			$log = $M->{event}{event}{default}{lc $role}{logging};
			$syslog = $M->{event}{event}{default}{lc $role}{syslog} if ($M->{event}{event}{default}{lc $role}{syslog} ne "");
		}
		else {
			$mdl_level = 'Major';
			# not found, use default
			dbg("no custom event level found for node=$NI->{system}{name}, event=$event, role=$role, model=$NI->{system}{nodeModel}, using '$mdl_level'");
		}
	}
	# Level set by custom!
	### 2013-03-08 keiths, adding policy based logging for Alerts.
	# We don't get the level but we can get the logging policy.
	# changed handling Proactive and Alert events to only use policy if found, default is kept
	elsif ( $event =~ /^Proactive|^Alert/i ) {
		if ( $event =~ /^Alert/i ) { $pol_event = "alert"; }
		elsif ( $event =~ /^Proactive/i ) { $pol_event = "proactive"; }

		$log = $M->{event}{event}{lc $pol_event}{lc $role}{logging} if defined $M->{event}{event}{lc $pol_event}{lc $role}{logging};
		$syslog = $M->{event}{event}{lc $pol_event}{lc $role}{syslog} if defined $M->{event}{event}{lc $pol_event}{lc $role}{syslog};
	}

	# overwrite the level argument if it wasn't set AND if the models reported something useful
	if ($mdl_level && !defined $level) {
		$level = $mdl_level;
	}
	return ($level,$log,$syslog);
}

# extract summary data for a given period from rrd files,
# via non-graph rrd graph declarations
sub getSummaryStats
{
	my %args = @_;
	my $type = $args{type};
	my $index = $args{index}; # optional
	my $item = $args{item};
	my $start = $args{start};
	my $end = $args{end};

	my $S = $args{sys};
	my $NI = $S->ndinfo;
	my $IF = $S->ifinfo;
	my $M  = $S->mdl;

	my $C = loadConfTable();
	if (getbool($C->{server_master}) and $NI->{system}{server}
			and lc($NI->{system}{server}) ne lc($C->{server_name}))
	{
		# send request to remote server
		dbg("serverConnect to $NI->{system}{server} for node=$S->{node}");
		#return serverConnect(server=>$NI->{system}{server},type=>'send',func=>'summary',node=>$S->{node},
		#		gtype=>$type,start=>$start,end=>$end,index=>$index,item=>$item);
	}

	my $db;
	my $ERROR;
	my ($graphret,$xs,$ys);
	my @option;
	my %summaryStats;

	dbg("Start type=$type, index=$index, start=$start, end=$end");

	# check if type exist in nodeInfo
	if (!($db = $S->getDBName(graphtype=>$type,index=>$index,item=>$item)))
	{
		# fixme: should this be logged as error? likely not, as common-bla models set
		# up all kinds of things that don't work everywhere...
		#logMsg("ERROR ($S->{name}) no rrd name found for type $type, index $index, item $item");
		return;
	}

	# check if rrd option rules exist in Model for stats
	if ($M->{stats}{type}{$type} eq "") {
		dbg("WARN ($S->{name}) type=$type not found in section stats of model=$NI->{system}{nodeModel}");
		logMsg("WARN ($S->{name}) type=$type not found in section stats of model=$NI->{system}{nodeModel}") if getbool($C->{log_model_messages});
		return;
	}

	# check if rrd file exists - note that this is NOT an error if the db belongs to
	# a section with source X but source X isn't enabled (e.g. only wmi or only snmp)
	if (! -e $db )
	{
		# unfortunately the sys object here is generally NOT a live one
		# (ie. not init'd with snmp/wmi=true), so we use the PreciseNodeStatus workaround
		# to figure out if the right source is enabled
		my %status = PreciseNodeStatus(system => $S);
		# fixme unclear how to find the model's rrd section for this thing?

		my $severity = "INFO";
		my $message = "$severity ($S->{name}) database=$db does not exist, snmp is "
					 .($status{snmp_enabled}?"enabled":"disabled").", wmi is "
					 .($status{wmi_enabled}?"enabled":"disabled");
		dbg($message);
		logMsg($message) if getbool($C->{log_model_messages});
		return;
	}

	push @option, ("--start", "$start", "--end", "$end") ;

	{
		no strict;									# *shudder* this is wrong, so wrong
		$database = $db; # global
		$speed = $IF->{$index}{ifSpeed} if $index ne "";
		$inSpeed = $IF->{$index}{ifSpeed} if $index ne "";
		$outSpeed = $IF->{$index}{ifSpeed} if $index ne "";
		$inSpeed = $IF->{$index}{ifSpeedIn} if $index ne "" and $IF->{$index}{ifSpeedIn};
		$outSpeed = $IF->{$index}{ifSpeedOut} if $index ne "" and $IF->{$index}{ifSpeedOut};

		# read from Model and translate variable ($database etc.) rrd options
		# note that all inputs need colon-escaping, not just the database
		foreach my $str (@{$M->{stats}{type}{$type}}) {
			my $s = $str;
			$s =~ s{\$(\w+)}{if(defined${$1}){postcolonial(${$1});}else{"ERROR, no variable \$$1 ";}}egx;
			if ($s =~ /ERROR/) {
				logMsg("ERROR ($S->{name}) model=$NI->{system}{nodeModel} type=$type ($str) in expanding variables, $s");
				return; # error
			}
			push @option, $s;
		}
	}
	if (getbool($C->{debug})) {
		foreach (@option) {
			dbg("option=$_",2);
		}
	}

	($graphret,$xs,$ys) = RRDs::graph('/dev/null', @option);
	if (($ERROR = RRDs::error)) {
		dbg("WARN ($S->{name}) RRD graph error database=$db: $ERROR");
		logMsg("WARN ($S->{name}) RRD graph error database=$db: $ERROR") if getbool($C->{log_model_messages});
	} else {
		##logMsg("INFO result type=$type, node=$NI->{system}{name}, $NI->{system}{nodeType}, $NI->{system}{nodeModel}, @$graphret");
		if ( scalar(@$graphret) ) {
			map { s/nan/NaN/g } @$graphret;			# make sure a NaN is returned !!
			foreach my $line ( @$graphret ) {
				my ($name,$value) = split "=", $line;
				if ($index ne "") {
					$summaryStats{$index}{$name} = $value; # use $index as primairy key
				} else {
					$summaryStats{$name} = $value;
				}
				dbg("name=$name, index=$index, value=$value",2);
				##logMsg("INFO name=$name, index=$index, value=$value");
			}
			return \%summaryStats;
		} else {
			logMsg("INFO ($S->{name}) no info return from RRD for type=$type index=$index item=$item");
		}
	}
	return;
}

# whatever it is that goes into rrdgraph arguments, colons are Not Good
sub postcolonial
{
	my ($unsafe) = @_;
	# but escaping already escaped colons isn't that much better
	$unsafe =~ s/(?<!\\):/\\:/g;
	return $unsafe;
}

sub getNodeSummary {
	my %args = @_;
	my $C = $args{C};
	my $group = $args{group};

	my $NT = loadLocalNodeTable();
	my %nt;

	my $node_summary_field_list = "customer,businessService";
	if ( defined $C->{node_summary_field_list} and $C->{node_summary_field_list} ne "" ) {
		$node_summary_field_list = $C->{node_summary_field_list};
	}

	my @node_summary_properties = split(",",$node_summary_field_list);

	foreach my $nd (keys %{$NT}) {
		next if (!getbool($NT->{$nd}{active}));
		next if $group ne '' and $NT->{$nd}{group} !~ /$group/;

		my $NI = loadNodeInfoTable($nd);

		$nt{$nd}{name} = $NI->{system}{name};
		$nt{$nd}{group} = $NI->{system}{group};
		$nt{$nd}{collect} = $NI->{system}{collect};
		$nt{$nd}{active} = $NT->{$nd}{active};
		$nt{$nd}{ping} = $NT->{$nd}{ping};
		$nt{$nd}{netType} = $NI->{system}{netType};
		$nt{$nd}{roleType} = $NI->{system}{roleType};
		$nt{$nd}{nodeType} = $NI->{system}{nodeType};
		$nt{$nd}{nodeModel} = $NI->{system}{nodeModel};
		$nt{$nd}{nodeVendor} = $NI->{system}{nodeVendor};
		$nt{$nd}{last_poll} = $NI->{system}{last_poll};
		$nt{$nd}{sysName} = $NI->{system}{sysName} ;
		$nt{$nd}{server} = $C->{'server_name'};

		foreach my $property (@node_summary_properties) {
			$nt{$nd}{$property} = $NI->{system}{$property};
		}

		$nt{$nd}{nodedown} = $NI->{system}{nodedown};
		# find out if a node down event exists, and if so store
		# its escalate setting
		my $curescalate = undef;
		if (my $eventexists = eventExist($nd, "Node Down", undef))
		{
			my $erec = eventLoad(filename => $eventexists);
			$curescalate = $erec->{escalate} if ($erec);
		}
		$nt{$nd}{escalate} = $curescalate;

		### adding node_status to the summary data
		# check status from event db
		my $nodestatus = nodeStatus(NI => $NI);
		if ( not $nodestatus ) {
			$nt{$nd}{nodestatus} = "unreachable";
		}
		elsif ( $nodestatus == -1 ) {
			$nt{$nd}{nodestatus} = "degraded";
		}
		else {
			$nt{$nd}{nodestatus} = "reachable";
		}

		my ($otgStatus,$otgHash) = outageCheck(node=>$nd, time=>time());
		my $outageText;

		if ( $otgStatus eq "current" or $otgStatus eq "pending") {
			my $color = ( $otgStatus eq "current" ) ? "#00AA00" : "#FFFF00";

			my $outageText = "node=$nd<br>start=".returnDateStamp($otgHash->{actual_start})
			."<br>end=".returnDateStamp($otgHash->{actual_end})."<br>change=$otgHash->{change_id}";
		}
		$nt{$nd}{outage} = $otgStatus;
		$nt{$nd}{outageText} = $outageText;

		# If sysLocation is formatted for GeoStyle, then remove long, lat and alt to make display tidier
		my $sysLocation = $NI->{system}{sysLocation};
		if (($NI->{system}{sysLocation}  =~ /$C->{sysLoc_format}/ ) and $C->{sysLoc} eq "on") {
			# Node has sysLocation that is formatted for Geo Data
			( my $lat, my $long, my $alt, $sysLocation) = split(',',$NI->{system}{sysLocation});
		}
		$nt{$nd}{sysLocation} = $sysLocation ;
	}
	return \%nt;
}

### AS 9/4/01 added getGroupSummary for doing the metric stuff centrally!
### AS 24/5/01 fixed so that colors show for things which aren't complete
### also reweighted the metric to be reachability = %40, availability = %20
### and health = %40
### AS 16 Mar 02, implementing David Gay's requirement for deactiving
### a node, ie keep a node in nodes.csv but no collection done.
### AS 16 Mar 02, implemented configurable reachability, availability, health
### AS 3 Jun 02, fixed up blank dash, insert N/A for nasty things
### ehg 17 sep 02 add nan to the trap for nasty things
### ehg 17 sep 02 counted actual nodes down for summary display
sub getGroupSummary {
	my %args = @_;
	my $group = $args{group};
	my $customer = $args{customer};
	my $business = $args{business};
	my $start_time = $args{start};
	my $end_time = $args{end};

	my @tmpsplit;
	my @tmparray;

	my $SUM = undef;
	my $reportStats;
	my %nodecount = ();
	my $node;
	my $index;
	my $cache = 0;
	my $filename;

	dbg("Starting");

	my (@devicelist,$i,@nodedetails);
	# init the hash, so zero values display
	$nodecount{counttotal} = 0;
	$nodecount{countup} = 0;
	$nodecount{countdown} = 0;
	$nodecount{countdegraded} = 0;

	my $S = Sys::->new;
	my $NT = loadNodeTable(); # local + nodes of remote servers
	my $C = loadConfTable();

	my $master_server_priority = $C->{master_server_priority} || 10;

	### 2014-08-28 keiths, configurable metric periods
	my $metricsFirstPeriod = defined $C->{'metric_comparison_first_period'} ? $C->{'metric_comparison_first_period'} : "-8 hours";
	my $metricsSecondPeriod = defined $C->{'metric_comparison_second_period'} ? $C->{'metric_comparison_second_period'} : "-16 hours";

	if ( $start_time eq "" ) { $start_time = $metricsFirstPeriod; }
	if ( $end_time eq "" ) { $end_time = time; }

	if ( $start_time eq $metricsFirstPeriod ) {
		$filename = "summary8h";
	}
	if ( $start_time eq $metricsSecondPeriod ) {
		$filename = "summary16h";
	}

	# load table (from cache)
	if ($filename ne "") {
		my $mtime;
		if ( (($SUM,$mtime) = loadTable(dir=>'var',name=>"nmis-$filename",mtime=>'true')) ) {
			if ($mtime < (time()-900)) {
				logMsg("INFO (nmis) cache file var/nmis-$filename does not exist or is old; calculate summary");
			} else {
				$cache = 1;
			}
		}
	}	else {
		logMsg("ERROR (nmis) missing summary file specification");
		return;
	}

	dbg("Cache is $cache, filename=$filename");

	# this server
	unless ($cache) {
		$SUM = {};
		foreach my $node ( keys %{$NT} ) {
			next if ( !getbool($NT->{$node}{active}) or exists $NT->{$node}{server});
			$SUM->{$node}{server_priority} = $master_server_priority;
			$SUM->{$node}{reachable} = 'NaN';
			$SUM->{$node}{response} = 'NaN';
			$SUM->{$node}{loss} = 'NaN';
			$SUM->{$node}{health} = 'NaN';
			$SUM->{$node}{available} = 'NaN';
			$SUM->{$node}{intfCollect} = 0;
			$SUM->{$node}{intfColUp} = 0;

			my $stats;
			if (($stats = getSummaryStats(sys=>$S,type=>"health",start=>$start_time,end=>$end_time,index=>$node))) {
				foreach (keys %{$stats}) { $SUM->{$node}{$_} = $stats->{$_};  }
			}

			# The other way to get node status is to ask Event State DB.
			if ( eventExist($node, "Node Down", undef) ) {
				$SUM->{$node}{nodedown} = "true";
			}
			else {
				$SUM->{$node}{nodedown} = "false";
			}

		}
	}

	### 2011-12-30 keiths, loading node summary from cached file!
	my $nodesum = "nmis-nodesum";
	# I should now have an up to date file, if I don't log a message
	if (existFile(dir=>'var',name=>$nodesum) ) {
		my $NS = loadTable(dir=>'var',name=>$nodesum);
		for my $node (keys %{$NS}) {
			#if ( $group eq "" or $group eq $NS->{$node}{group} ) {
			if ( 	($group eq "" and $customer eq "" and $business eq "")
				 		or ($group ne "" and $NT->{$node}{group} eq $group)
						or ($customer ne "" and $NT->{$node}{customer} eq $customer)
						or ($business ne "" and $NT->{$node}{businessService} =~ /$business/ )
			) {
				for (keys %{$NS->{$node}}) {
					$SUM->{$node}{$_} = $NS->{$node}{$_};
				}
			}
		}
	}


	### 2011-12-29 keiths, moving master handling outside of Cache handling!
	if (getbool($C->{server_master})) {
		dbg("Master, processing Slave Servers");
		my $ST = loadServersTable();
		for my $srv (keys %{$ST}) {
			## don't process server localhost for opHA2
			next if $srv eq "localhost";

			my $server_priority = $ST->{$srv}{server_priority} || 5;

			my $slavefile = "nmis-$srv-$filename";
			dbg("Processing Slave $srv for $slavefile");

			# I should now have an up to date file, if I don't log a message
			if (existFile(dir=>'var',name=>$slavefile) ) {
				my $H = loadTable(dir=>'var',name=>$slavefile);
				for my $node (keys %{$H}) {
					if ( not exists $SUM->{$node}
							or $SUM->{$node}{server} eq $srv
							or ( exists $SUM->{$node}
								and $SUM->{$node}{server_priority}
								and $SUM->{$node}{server_priority} < $server_priority
								)
					) {
						for (keys %{$H->{$node}}) {
							$SUM->{$node}{$_} = $H->{$node}{$_};
						}
						$SUM->{$node}{server_priority} = $server_priority;
						$SUM->{$node}{server} = $srv;
					}
				}
			}

			my $slavenodesum = "nmis-$srv-nodesum";
			dbg("Processing Slave $srv for $slavenodesum");
			# I should now have an up to date file, if I don't log a message
			if (existFile(dir=>'var',name=>$slavenodesum) ) {

				my $NS = loadTable(dir=>'var',name=>$slavenodesum);
				for my $node (keys %{$NS}) {
					if ( 	($group eq "" and $customer eq "" and $business eq "")
				 				or ($group ne "" and $NS->{$node}{group} eq $group)
								or ($customer ne "" and $NS->{$node}{customer} eq $customer)
								or ($business ne "" and $NS->{$node}{businessService} =~ /$business/)
					) {
						if ( not exists $SUM->{$node}
								or $SUM->{$node}{server} eq $srv
								or ( exists $SUM->{$node}
									and $SUM->{$node}{server_priority}
									and $SUM->{$node}{server_priority} < $server_priority
									)
						) {
							for (keys %{$NS->{$node}}) {
								$SUM->{$node}{$_} = $NS->{$node}{$_};
							}
							$SUM->{$node}{server_priority} = $server_priority;
							$SUM->{$node}{server} = $srv;
						}
					}
				}
			}
		}
	}

	# copy this hash for modification
	my %summaryHash = %{$SUM} if defined $SUM;

	# Insert some nice status info about the devices for the summary menu.
NODE:
	foreach $node (sort keys %{$NT} ) {
		# Only do the group - or everything if no group passed to us.
		if (	($group eq "" and $customer eq "" and $business eq "")
				 	or ($group ne "" and $NT->{$node}{group} eq $group)
					or ($customer ne "" and $NT->{$node}{customer} eq $customer)
					or ($business ne "" and $NT->{$node}{businessService} =~ /$business/)
		) {
			if ( getbool($NT->{$node}{active}) ) {
				++$nodecount{counttotal};
				my $outage = '';
				# check nodes
				# Carefull logic here, if nodedown is false then the node is up
				#print STDERR "DEBUG: node=$node nodedown=$summaryHash{$node}{nodedown}\n";
				if (getbool($summaryHash{$node}{nodedown})) {
					($summaryHash{$node}{event_status},$summaryHash{$node}{event_color}) = eventLevel("Node Down",$NT->{$node}{roleType});
					++$nodecount{countdown};
					($outage,undef) = outageCheck(node=>$node,time=>time());
				}
				elsif (exists $C->{display_status_summary}
					and getbool($C->{display_status_summary})
					and exists $summaryHash{$node}{nodestatus}
					and $summaryHash{$node}{nodestatus} eq "degraded"
				) {
					$summaryHash{$node}{event_status} = "Error";
					$summaryHash{$node}{event_color} = "#ffff00";
					++$nodecount{countdegraded};
					($outage,undef) = outageCheck(node=>$node,time=>time());
				}
				else {
					($summaryHash{$node}{event_status},$summaryHash{$node}{event_color}) = eventLevel("Node Up",$NT->{$node}{roleType});
					++$nodecount{countup};
				}

				# dont if outage current with node down
				if ($outage ne 'current') {
					if ( $summaryHash{$node}{reachable} !~ /NaN/i	) {
						++$nodecount{reachable};
						$summaryHash{$node}{reachable_color} = colorHighGood($summaryHash{$node}{reachable});
						$summaryHash{total}{reachable} = $summaryHash{total}{reachable} + $summaryHash{$node}{reachable};
					} else { $summaryHash{$node}{reachable} = "NaN" }

					if ( $summaryHash{$node}{available} !~ /NaN/i ) {
						++$nodecount{available};
						$summaryHash{$node}{available_color} = colorHighGood($summaryHash{$node}{available});
						$summaryHash{total}{available} = $summaryHash{total}{available} + $summaryHash{$node}{available};
					} else { $summaryHash{$node}{available} = "NaN" }

					if ( $summaryHash{$node}{health} !~ /NaN/i ) {
						++$nodecount{health};
						$summaryHash{$node}{health_color} = colorHighGood($summaryHash{$node}{health});
						$summaryHash{total}{health} = $summaryHash{total}{health} + $summaryHash{$node}{health};
					} else { $summaryHash{$node}{health} = "NaN" }

					if ( $summaryHash{$node}{response} !~ /NaN/i ) {
						++$nodecount{response};
						$summaryHash{$node}{response_color} = colorResponseTime($summaryHash{$node}{response});
						$summaryHash{total}{response} = $summaryHash{total}{response} + $summaryHash{$node}{response};
					} else { $summaryHash{$node}{response} = "NaN" }

					if ( $summaryHash{$node}{intfCollect} !~ /NaN/i ) {
						++$nodecount{intfCollect};
						$summaryHash{total}{intfCollect} = $summaryHash{total}{intfCollect} + $summaryHash{$node}{intfCollect};
					} else { $summaryHash{$node}{intfCollect} = "NaN" }

					if ( $summaryHash{$node}{intfColUp} !~ /NaN/i ) {
						++$nodecount{intfColUp};
						$summaryHash{total}{intfColUp} = $summaryHash{total}{intfColUp} + $summaryHash{$node}{intfColUp};
					} else { $summaryHash{$node}{intfColUp} = "NaN" }
				} else {
		###			logMsg("INFO Node=$node skipped OU=$outage");
				}

			} else {
				# node not active
				$summaryHash{$node}{event_status} = "N/A";
				$summaryHash{$node}{reachable} = "N/A";
				$summaryHash{$node}{available} = "N/A";
				$summaryHash{$node}{health} = "N/A";
				$summaryHash{$node}{response} = "N/A";
				$summaryHash{$node}{event_color} = "#aaaaaa";
				$summaryHash{$node}{reachable_color} = "#aaaaaa";
				$summaryHash{$node}{available_color} = "#aaaaaa";
				$summaryHash{$node}{health_color} = "#aaaaaa";
				$summaryHash{$node}{response_color} = "#aaaaaa";
			}
		}
		# node not part of the selection (group/customer/businessservice),
		# don't include it in the response
		else
		{
			delete $summaryHash{$node};
		}
	}

	if ( $summaryHash{total}{reachable} > 0 ) {
		$summaryHash{average}{reachable} = sprintf("%.3f",$summaryHash{total}{reachable} / $nodecount{reachable} );
	}
	if ( $summaryHash{total}{available} > 0 ) {
		$summaryHash{average}{available} = sprintf("%.3f",$summaryHash{total}{available} / $nodecount{available} );
	}
	if ( $summaryHash{total}{health} > 0 ) {
		$summaryHash{average}{health} = sprintf("%.3f",$summaryHash{total}{health} / $nodecount{health} );
	}
	if ( $summaryHash{total}{response} > 0 ) {
		# Changing default precision to 1 decimal, as changing to 3 might mess up many screens.
		$summaryHash{average}{response} = sprintf("%.1f",$summaryHash{total}{response} / $nodecount{response} );
	}

	if ( $summaryHash{total}{reachable} > 0 and $summaryHash{total}{available} > 0 and $summaryHash{total}{health} > 0 ) {
		# new weighting for metric
		$summaryHash{average}{metric} = sprintf("%.3f",(
			( $summaryHash{average}{reachable} * $C->{metric_reachability} ) +
			( $summaryHash{average}{available} * $C->{metric_availability} ) +
			( $summaryHash{average}{health} ) * $C->{metric_health} )
		);
	}

	# interface availability calculation NEW
	if ($nodecount{intfColUp} > 0 and $nodecount{intfCollect} > 0 and
			$summaryHash{total}{intfColUp} > 0 and $summaryHash{total}{intfCollect} > 0) {
		$summaryHash{average}{intfAvail} = (($summaryHash{total}{intfColUp} / $nodecount{intfColUp}) /
										($summaryHash{total}{intfCollect} / $nodecount{intfCollect})) * 100;
	} else {
		$summaryHash{average}{intfAvail} = 100;
	}

	$summaryHash{average}{intfColUp} = $summaryHash{total}{intfColUp} eq '' ? 0 : $summaryHash{total}{intfColUp};
	$summaryHash{average}{intfCollect} = $summaryHash{total}{intfCollect} eq '' ? 0 : $summaryHash{total}{intfCollect};

	$summaryHash{average}{countdown} = $nodecount{countdown};
	$summaryHash{average}{countdegraded} = $nodecount{countdegraded};
	### 2012-12-17 keiths, fixed divide by zero error when doing group status summaries
	if ( $nodecount{countdown} > 0 and $nodecount{counttotal} > 0 ) {
		$summaryHash{average}{countdowncolor} = ($nodecount{countdown}/$nodecount{counttotal})*100;
	}
	else {
		$summaryHash{average}{countdowncolor} = 0;
	}

	$summaryHash{average}{counttotal} = $nodecount{counttotal};
	$summaryHash{average}{countup} = $nodecount{countup};

	# Now the summaryHash is full, calc some colors and check for empty results.
	if ( $summaryHash{average}{reachable} ne "" ) {
		$summaryHash{average}{reachable} = 100 if $summaryHash{average}{reachable} > 100 ;
		$summaryHash{average}{reachable_color} = colorHighGood($summaryHash{average}{reachable})
	}
	else {
		$summaryHash{average}{reachable_color} = "#aaaaaa";
		$summaryHash{average}{reachable} = "N/A";
	}

	# modification of interface available calculation
	if (getbool($C->{intf_av_modified})) {
		$summaryHash{average}{available} =
				sprintf("%.3f",($summaryHash{total}{intfColUp} / $summaryHash{total}{intfCollect}) * 100 );
	}

	if ( $summaryHash{average}{available} ne "" ) {
		$summaryHash{average}{available} = 100 if $summaryHash{average}{available} > 100 ;
		$summaryHash{average}{available_color} = colorHighGood($summaryHash{average}{available});
	}
	else {
		$summaryHash{average}{available_color} = "#aaaaaa";
		$summaryHash{average}{available} = "N/A";
	}

	if ( $summaryHash{average}{health} ne "" ) {
		$summaryHash{average}{health} = 100 if $summaryHash{average}{health} > 100 ;
		$summaryHash{average}{health_color} = colorHighGood($summaryHash{average}{health});
	}
	else {
		$summaryHash{average}{health_color} = "#aaaaaa";
		$summaryHash{average}{health} = "N/A";
	}

	if ( $summaryHash{average}{response} ne "" ) {
		$summaryHash{average}{response_color} = colorResponseTime($summaryHash{average}{response})
	}
	else {
		$summaryHash{average}{response_color} = "#aaaaaa";
		$summaryHash{average}{response} = "N/A";
	}

	if ( $summaryHash{average}{metric} ne "" ) {
		$summaryHash{average}{metric} = 100 if $summaryHash{average}{metric} > 100 ;
		$summaryHash{average}{metric_color} = colorHighGood($summaryHash{average}{metric})
	}
	else {
		$summaryHash{average}{metric_color} = "#aaaaaa";
		$summaryHash{average}{metric} = "N/A";
	}
	dbg("Finished");
	return \%summaryHash;
} # end getGroupSummary

#=========================================================================================

sub getAdminColor {
	my %args = @_;
	my ($S,$index,$IF);
	if ( exists $args{sys} ) {
		$S = $args{sys};
		$index = $args{index};
		$IF = $S->ifinfo;
	}
	my $adminColor;

	my $ifAdminStatus = $IF->{$index}{ifAdminStatus};
	my $collect = $IF->{$index}{collect};

	if ( $index eq "" ) {
		$ifAdminStatus = $args{ifAdminStatus};
		$collect = $args{collect};
	}

	if ( $ifAdminStatus =~ /down|testing|null|unknown/ or !getbool($collect)) {
		$adminColor="#ffffff";
	} else {
		$adminColor="#00ff00";
	}
	return $adminColor;
}

#=========================================================================================

sub getOperColor {
	my %args = @_;
	my ($S,$NI,$index,$IF);
	if ( exists $args{sys} ) {
		$S = $args{sys};
		$index = $args{index};
		$IF = $S->ifinfo;
	}
	my $operColor;

	my $ifAdminStatus = $IF->{$index}{ifAdminStatus};
	my $ifOperStatus = $IF->{$index}{ifOperStatus};
	my $collect = $IF->{$index}{collect};

	if ( $index eq "" ) {
		$ifAdminStatus = $args{ifAdminStatus};
		$ifOperStatus = $args{ifOperStatus};
		$collect = $args{collect};
	}

	if ( $ifAdminStatus =~ /down|testing|null|unknown/ or !getbool($collect)) {
		$operColor="#ffffff"; # white
	} else {
		if ($ifOperStatus eq 'down') {
			# red for down
			$operColor = "#ff0000";
		} elsif ($ifOperStatus eq 'dormant') {
			# yellow for dormant
			$operColor = "#ffff00";
		} else { $operColor = "#00ff00"; } # green
	}
	return $operColor;
}

sub colorHighGood {
	my $threshold = shift;
	my $color = "";

	if ( ( $threshold =~ /^[a-zA-Z]/ ) || ( $threshold eq "") )  { $color = "#FFFFFF"; }
	elsif ( $threshold eq "N/A" )  { $color = "#FFFFFF"; }
	elsif ( $threshold >= 100 ) { $color = "#00FF00"; }
	elsif ( $threshold >= 95 ) { $color = "#00EE00"; }
	elsif ( $threshold >= 90 ) { $color = "#00DD00"; }
	elsif ( $threshold >= 85 ) { $color = "#00CC00"; }
	elsif ( $threshold >= 80 ) { $color = "#00BB00"; }
	elsif ( $threshold >= 75 ) { $color = "#00AA00"; }
	elsif ( $threshold >= 70 ) { $color = "#009900"; }
	elsif ( $threshold >= 65 ) { $color = "#008800"; }
	elsif ( $threshold >= 60 ) { $color = "#FFFF00"; }
	elsif ( $threshold >= 55 ) { $color = "#FFEE00"; }
	elsif ( $threshold >= 50 ) { $color = "#FFDD00"; }
	elsif ( $threshold >= 45 ) { $color = "#FFCC00"; }
	elsif ( $threshold >= 40 ) { $color = "#FFBB00"; }
	elsif ( $threshold >= 35 ) { $color = "#FFAA00"; }
	elsif ( $threshold >= 30 ) { $color = "#FF9900"; }
	elsif ( $threshold >= 25 ) { $color = "#FF8800"; }
	elsif ( $threshold >= 20 ) { $color = "#FF7700"; }
	elsif ( $threshold >= 15 ) { $color = "#FF6600"; }
	elsif ( $threshold >= 10 ) { $color = "#FF5500"; }
	elsif ( $threshold >= 5 )  { $color = "#FF3300"; }
	elsif ( $threshold > 0 )   { $color = "#FF1100"; }
	elsif ( $threshold == 0 )  { $color = "#FF0000"; }
	elsif ( $threshold == 0 )  { $color = "#FF0000"; }

	return $color;
}

sub colorPort {
	my $threshold = shift;
	my $color = "";

	if ( $threshold >= 60 ) { $color = "#FFFF00"; }
	elsif ( $threshold < 60 ) { $color = "#00FF00"; }

	return $color;
}

sub colorLowGood {
	my $threshold = shift;
	my $color = "";

	if ( ( $threshold =~ /^[a-zA-Z]/ ) || ( $threshold eq "") )  { $color = "#FFFFFF"; }
	elsif ( $threshold == 0 ) { $color = "#00FF00"; }
	elsif ( $threshold <= 5 ) { $color = "#00EE00"; }
	elsif ( $threshold <= 10 ) { $color = "#00DD00"; }
	elsif ( $threshold <= 15 ) { $color = "#00CC00"; }
	elsif ( $threshold <= 20 ) { $color = "#00BB00"; }
	elsif ( $threshold <= 25 ) { $color = "#00AA00"; }
	elsif ( $threshold <= 30 ) { $color = "#009900"; }
	elsif ( $threshold <= 35 ) { $color = "#008800"; }
	elsif ( $threshold <= 40 ) { $color = "#FFFF00"; }
	elsif ( $threshold <= 45 ) { $color = "#FFEE00"; }
	elsif ( $threshold <= 50 ) { $color = "#FFDD00"; }
	elsif ( $threshold <= 55 ) { $color = "#FFCC00"; }
	elsif ( $threshold <= 60 ) { $color = "#FFBB00"; }
	elsif ( $threshold <= 65 ) { $color = "#FFAA00"; }
	elsif ( $threshold <= 70 ) { $color = "#FF9900"; }
	elsif ( $threshold <= 75 ) { $color = "#FF8800"; }
	elsif ( $threshold <= 80 ) { $color = "#FF7700"; }
	elsif ( $threshold <= 85 ) { $color = "#FF6600"; }
	elsif ( $threshold <= 90 ) { $color = "#FF5500"; }
	elsif ( $threshold <= 95 ) { $color = "#FF4400"; }
	elsif ( $threshold < 100 ) { $color = "#FF3300"; }
	elsif ( $threshold == 100 )  { $color = "#FF1100"; }
	elsif ( $threshold <= 110 )  { $color = "#FF0055"; }
	elsif ( $threshold <= 120 )  { $color = "#FF0066"; }
	elsif ( $threshold <= 130 )  { $color = "#FF0077"; }
	elsif ( $threshold <= 140 )  { $color = "#FF0088"; }
	elsif ( $threshold <= 150 )  { $color = "#FF0099"; }
	elsif ( $threshold <= 160 )  { $color = "#FF00AA"; }
	elsif ( $threshold <= 170 )  { $color = "#FF00BB"; }
	elsif ( $threshold <= 180 )  { $color = "#FF00CC"; }
	elsif ( $threshold <= 190 )  { $color = "#FF00DD"; }
	elsif ( $threshold <= 200 )  { $color = "#FF00EE"; }
	elsif ( $threshold > 200 )  { $color = "#FF00FF"; }

	return $color;
}

sub colorResponseTimeStatic {
	my $threshold = shift;
	my $color = "";

	if ( ( $threshold =~ /^[a-zA-Z]/ ) || ( $threshold eq "") )  { $color = "#FFFFFF"; }
	elsif ( $threshold <= 1 ) { $color = "#00FF00"; }
	elsif ( $threshold <= 20 ) { $color = "#00EE00"; }
	elsif ( $threshold <= 50 ) { $color = "#00DD00"; }
	elsif ( $threshold <= 100 ) { $color = "#00CC00"; }
	elsif ( $threshold <= 200 ) { $color = "#00BB00"; }
	elsif ( $threshold <= 250 ) { $color = "#00AA00"; }
	elsif ( $threshold <= 300 ) { $color = "#009900"; }
	elsif ( $threshold <= 350 ) { $color = "#FFFF00"; }
	elsif ( $threshold <= 400 ) { $color = "#FFEE00"; }
	elsif ( $threshold <= 450 ) { $color = "#FFDD00"; }
	elsif ( $threshold <= 500 ) { $color = "#FFCC00"; }
	elsif ( $threshold <= 550 ) { $color = "#FFBB00"; }
	elsif ( $threshold <= 600 ) { $color = "#FFAA00"; }
	elsif ( $threshold <= 650 ) { $color = "#FF9900"; }
	elsif ( $threshold <= 700 ) { $color = "#FF8800"; }
	elsif ( $threshold <= 750 ) { $color = "#FF7700"; }
	elsif ( $threshold <= 800 ) { $color = "#FF6600"; }
	elsif ( $threshold <= 850 ) { $color = "#FF5500"; }
	elsif ( $threshold <= 900 ) { $color = "#FF4400"; }
	elsif ( $threshold <= 950 )  { $color = "#FF3300"; }
	elsif ( $threshold < 1000 )   { $color = "#FF1100"; }
	elsif ( $threshold > 1000 )  { $color = "#FF0000"; }

	return $color;
}



# fixme: az looks like this function should be reworked with
# or ditched in favour of nodeStatus() and PreciseNodeStatus()
# fixme: this also doesn't understand wmidown (properly)
sub overallNodeStatus {
	my %args = @_;
	my $group = $args{group};
	my $customer = $args{customer};
	my $business = $args{business};
	my $netType = $args{netType};
	my $roleType = $args{roleType};

	if (scalar(@_) == 1) {
		$group = shift;
	}

	my $node;
	my $event_status;
	my $overall_status;
	my $status_number;
	my $total_status;
	my $multiplier;
	my $status;

	my %statusHash;

	my $C = loadConfTable();
	my $NT = loadNodeTable();
	my $NS = loadNodeSummary();

	foreach $node (sort keys %{$NT} )
	{
		next if (!getbool($NT->{$node}{active}));

		if (
			( $group eq "" and $customer eq "" and $business eq "" and $netType eq "" and $roleType eq "" )
			or
			( $netType ne "" and $roleType ne ""
				and $NT->{$node}{net} eq "$netType" && $NT->{$node}{role} eq "$roleType" )
			or ($group ne "" and $NT->{$node}{group} eq $group)
			or ($customer ne "" and $NT->{$node}{customer} eq $customer)
			or ($business ne "" and $NT->{$node}{businessService} =~ /$business/ ) )
		{
			my $nodedown = 0;
			my $outage = "";
			if ( $NT->{$node}{server} eq $C->{server_name} ) {
				### 2013-08-20 keiths, check for SNMP Down if ping eq false.
				my $down_event = "Node Down";
				$down_event = "SNMP Down" if getbool($NT->{$node}{ping},"invert");
				$nodedown = eventExist($node, $down_event, undef)? 1:0; # returns the event filename

				($outage,undef) = outageCheck(node=>$node,time=>time());
			}
			else {
				$outage = $NS->{$node}{outage};
				if ( getbool($NS->{$node}{nodedown})) {
					$nodedown = 1;
				}
			}

			if ( $nodedown and $outage ne 'current' ) {
				($event_status) = eventLevel("Node Down",$NT->{$node}{roleType});
			}
			else {
				($event_status) = eventLevel("Node Up",$NT->{$node}{roleType});
			}

			++$statusHash{$event_status};
			++$statusHash{count};
		}
	}

	$status_number = 100 * $statusHash{Normal};
	$status_number = $status_number + ( 90 * $statusHash{Warning} );
	$status_number = $status_number + ( 75 * $statusHash{Minor} );
	$status_number = $status_number + ( 60 * $statusHash{Major} );
	$status_number = $status_number + ( 50 * $statusHash{Critical} );
	$status_number = $status_number + ( 40 * $statusHash{Fatal} );
	if ( $status_number != 0 and $statusHash{count} != 0 ) {
		$status_number = $status_number / $statusHash{count};
	}
	#print STDERR "New CALC: status_number=$status_number count=$statusHash{count}\n";

	### 2014-08-27 keiths, adding a more coarse any nodes down is red
	if ( defined $C->{overall_node_status_coarse}
			 and getbool($C->{overall_node_status_coarse})) {
		$C->{overall_node_status_level} = "Critical" if not defined $C->{overall_node_status_level};
		if ( $status_number == 100 ) { $overall_status = "Normal"; }
		else { $overall_status = $C->{overall_node_status_level}; }
	}
	else {
		### AS 11/4/01 - Fixed up status for single node groups.
		# if the node count is one we do not require weighting.
		if ( $statusHash{count} == 1 ) {
			delete ($statusHash{count});
			foreach $status (keys %statusHash) {
				if ( $statusHash{$status} ne "" and $statusHash{$status} ne "count" ) {
					$overall_status = $status;
					#print STDERR returnDateStamp." overallNodeStatus netType=$netType status=$status hash=$statusHash{$status}\n";
				}
			}
		}
		elsif ( $status_number != 0  ) {
			if ( $status_number == 100 ) { $overall_status = "Normal"; }
			elsif ( $status_number >= 95 ) { $overall_status = "Warning"; }
			elsif ( $status_number >= 90 ) { $overall_status = "Minor"; }
			elsif ( $status_number >= 70 ) { $overall_status = "Major"; }
			elsif ( $status_number >= 50 ) { $overall_status = "Critical"; }
			elsif ( $status_number <= 40 ) { $overall_status = "Fatal"; }
			elsif ( $status_number >= 30 ) { $overall_status = "Disaster"; }
			elsif ( $status_number < 30 ) { $overall_status = "Catastrophic"; }
		}
		else {
			$overall_status = "Unknown";
		}
	}
	return $overall_status;
} # end overallNodeStatus

# convert configuration files in dir conf to NMIS8

sub convertConfFiles {

	my $C = loadConfTable();

	my $ext = getExtension(dir=>'conf');
	#==== check Nodes ====

	if (!existFile(dir=>'conf',name=>'Nodes')) {
		my %nodeTable;
		my $NT;
		# Load the old CSV first for upgrading to NMIS8 format
		if ( -r $C->{Nodes_Table} ) {
			if ( (%nodeTable = &loadCSV($C->{Nodes_Table},$C->{Nodes_Key},"\t")) ) {
				dbg("Loaded $C->{Nodes_Table}");
				rename "$C->{Nodes_Table}","$C->{Nodes_Table}.old";
				# copy what we need
				foreach my $i (sort keys %nodeTable) {
					dbg("update node=$nodeTable{$i}{node} to NMIS8 format");
					# new field 'name' and 'host' in NMIS8, update this field
					if ($nodeTable{$i}{node} =~ /(\d+)\.(\d+)\.(\d+)\.(\d+)/) {
						$nodeTable{$i}{name} = sprintf("IP-%03d-%03d-%03d-%03d",${1},${2},${3},${4}); # default
						# it's an IP address, get the DNS name
						my $iaddr = inet_aton($nodeTable{$i}{node});
						if ((my $name  = gethostbyaddr($iaddr, AF_INET))) {
							$nodeTable{$i}{name} = $name; # oke
							dbg("node=$nodeTable{$i}{node} converted to name=$name");
						} else {
							# look for sysName of nmis4
							if ( -f "$C->{'<nmis_var>'}/$nodeTable{$i}{node}.dat" ) {
								my (%info,$name,$value);
								sysopen(DATAFILE, "$C->{'<nmis_var>'}/$nodeTable{$i}{node}.dat", O_RDONLY);
								while (<DATAFILE>) {
									chomp;
									if ( $_ !~ /^#/ ) {
										($name,$value) = split "=", $_;
										$info{$name} = $value;
									}
								}
								close(DATAFILE);
								if ($info{sysName} ne "") {
									$nodeTable{$i}{name} = $info{sysName};
									dbg("name=$name=$info{sysName} from sysName for node=$nodeTable{$i}{node}");
								}
							}
						}
					} else {
						$nodeTable{$i}{name} = $nodeTable{$i}{node}; # simple copy of DNS name
					}
					dbg("result 1 update name=$nodeTable{$i}{name}");
					# only first part of (fqdn) name
					($nodeTable{$i}{name}) = split /\./,$nodeTable{$i}{name} ;
					dbg("result update name=$nodeTable{$i}{name}");

					my $node = $nodeTable{$i}{name};
					$NT->{$node}{name} = $nodeTable{$i}{name};
					$NT->{$node}{host} = $nodeTable{$i}{host} || $nodeTable{$i}{node};
					$NT->{$node}{active} = $nodeTable{$i}{active};
					$NT->{$node}{collect} = $nodeTable{$i}{collect};
					$NT->{$node}{group} = $nodeTable{$i}{group};
					$NT->{$node}{netType} = $nodeTable{$i}{net} || $nodeTable{$i}{netType};
					$NT->{$node}{roleType} = $nodeTable{$i}{role} || $nodeTable{$i}{roleType};
					$NT->{$node}{depend} = $nodeTable{$i}{depend};
					$NT->{$node}{threshold} = $nodeTable{$i}{threshold} || 'false';
					$NT->{$node}{ping} = $nodeTable{$i}{ping} || 'true';
					$NT->{$node}{community} = $nodeTable{$i}{community};
					$NT->{$node}{port} = $nodeTable{$i}{port} || '161';
					$NT->{$node}{cbqos} = $nodeTable{$i}{cbqos} || 'none';
					$NT->{$node}{calls} = $nodeTable{$i}{calls} || 'false';
					$NT->{$node}{rancid} = $nodeTable{$i}{rancid} || 'false';
					$NT->{$node}{services} = $nodeTable{$i}{services} ;
				#	$NT->{$node}{runupdate} = $nodeTable{$i}{runupdate} ;
					$NT->{$node}{webserver} = 'false' ;
					$NT->{$node}{model} = $nodeTable{$i}{model} || 'automatic';
					$NT->{$node}{version} = $nodeTable{$i}{version} || 'snmpv2c';
					$NT->{$node}{timezone} = 0 ;
				}
				writeTable(dir=>'conf',name=>'Nodes',data=>$NT);
				print " csv file $C->{Nodes_Table} converted to conf/Nodes.$ext\n";
			} else {
				dbg("ERROR, could not find or read $C->{Nodes_Table} or empty node file");
			}
		} else {
			dbg("ERROR, could not find or read $C->{Nodes_Table}");
		}
	}


	#====================

	if (!existFile(dir=>'conf',name=>'Escalations')) {
		if ( -r "$C->{'Escalation_Table'}") {
			my %table_data = loadCSV($C->{'Escalation_Table'},$C->{'Escalation_Key'});
			foreach my $k (keys %table_data) {
				if (not exists $table_data{$k}{Event_Element}) {
					$table_data{$k}{Event_Element} = $table_data{$k}{Event_Details} ;
					delete $table_data{$k}{Event_Details};
				}
			}
			writeTable(dir=>'conf',name=>'Escalations',data=>\%table_data);
			print " csv file $C->{Escalation_Table} converted to conf/Escalation.$ext\n";
			rename "$C->{'Escalation_Table'}","$C->{'Escalation_Table'}.old";
		} else {
			dbg("ERROR, could not find or read $C->{'Escalation_Table'}");
		}
	}
	#====================

	convertFile('Contacts');

	convertFile('Locations');

	convertFile('Services');

	convertFile('Users');

	#====================

	sub convertFile {
		my $name = shift;
		my $C = loadConfTable();
		if (!existFile(dir=>'conf',name=>$name)) {
			if ( -r "$C->{\"${name}_Table\"}") {
				my %table_data = loadCSV($C->{"${name}_Table"},$C->{"${name}_Key"});
				writeTable(dir=>'conf',name=>$name,data=>\%table_data);

				my $ext = getExtension(dir=>'conf');
				print " csv file $C->{\"${name}_Table\"} converted to conf/${name}.$ext\n";
				rename "$C->{\"${name}_Table\"}","$C->{\"${name}_Table\"}.old";
			} else {
				dbg("ERROR, could not find or read $C->{\"${name}_Table\"}");
			}
		}
	}
}


### AS 8 June 2002 - Converts status level to a number for metrics
sub statusNumber {
	my $status = shift;
	my $level;
	if ( $status eq "Normal" ) { $level = 100 }
	elsif ( $status eq "Warning" ) { $level = 95 }
	elsif ( $status eq "Minor" ) { $level = 90 }
	elsif ( $status eq "Major" ) { $level = 80 }
	elsif ( $status eq "Critical" ) { $level = 60 }
	elsif ( $status eq "Fatal" ) { $level = 40 }
	elsif ( $status eq "Disaster" ) { $level = 20 }
	elsif ( $status eq "Catastrophic" ) { $level = 0 }
	elsif ( $status eq "Unknown" ) { $level = "U" }
	return $level;
}

# 24 Feb 2002 - A suggestion from someone? to remove \n from $string.
# this also prints the message if debug, remove concurrent debug prints in code...

sub logMessage {
	my $string = shift;
	my $C = loadConfTable();

	$string =~ s/\n+/ /g;      #remove all embedded newlines
	sysopen(DATAFILE, "$C->{nmis_log}", O_WRONLY | O_APPEND | O_CREAT)
		 or warn returnTime." logMessage, Couldn't open log file $C->{nmis_log}. $!\n";
	flock(DATAFILE, LOCK_EX) or warn "logMessage, can't lock filename: $!";
	print DATAFILE &returnDateStamp.",$string\n";
	close(DATAFILE) or warn "logMessage, can't close filename: $!";
} # end logMessage

# load the info of a node
# if optional arg suppress_errors is given, then no errors are logged
sub loadNodeInfoTable
{
	my $node = lc shift;
	my %args = @_;

	return loadTable(dir=>'var', name=>"$node-node",  suppress_errors => $args{suppress_errors});
}

# load info of all interfaces
sub loadInterfaceInfo {

	return loadTable(dir=>'var',name=>"nmis-interfaces"); # my $II = loadInterfaceInfo();
}

# load info of all interfaces
sub loadInterfaceInfoShort {

	return loadTable(dir=>'var',name=>"nmis-interfaces-short"); # my $II = loadInterfaceInfoShort();
}

#
sub loadEnterpriseTable {
	return loadTable(dir=>'conf',name=>'Enterprise');
}



# outage api

# outage data/argument structure:
#
# id (unique key, automatically generated on create, must be used for update and delete)
# frequency ('once', 'daily', 'weekly', 'monthly')
# start, end (a date/date+time/partial format that's suitable for the given frequency),
# change_id (required but free-form text, used to tag events),
# description (optional, free-form descriptive text),
# options (hash substructure that selects optional behaviours for this outage)
#   nostats (default undef, if set to 1 only 'U' values are written to rrds during the outage)
# selector (hash substructure that defines what devices this outage covers)
#  two category keys, 'node' and 'config'
#  under these there can be any number of key => value filter expressions
#  all filter expressions must match for the selector to match
#
#  selector key X needs to be a CONFIG! property of the node if under node,
#   (plus nodeModel from the node info), or a global nmis property if under config.
#
#  value: either array, or string or regex-string ('/.../' or '/.../i')
#  array: set of acceptable values; one or more must meet strict equality test for the selector succeed
#  single string: strict equality
#  regex-string: identified property must match


# create new or update existing outage
# note that updates are absolute, not relative to existing outage!
# you must pass all desired arguments, not only ones you want changed
#
# args: id IFF updating,
# frequency/start/end/description/change_id/options/selector,
# meta (hash, optional, for audit logging, keys user and details. if missing, user will
#  be set from os user of the current process)
# returns: hashref, keys success/error, id
sub update_outage
{
	my (%args) = @_;

	# validate the args first
	# lock and load existing outages,
	# create new one or update existing one,
	# save and unlock

	my $meta = ref($args{meta}) eq "HASH"? $args{meta} : {};
	$meta->{user} ||= (getpwuid($<))[0];

	my (%newrec, $op_create);
	my $outid = $args{id};

	if (!defined($outid) or $outid eq "") # 0 is ok, empty is not
	{
		$outid = NMIS::UUID::getRandomUUID();
		$op_create = 1;
	}
	$newrec{id} = $outid;

	# copy simple args
	for my $copyable (qw(description change_id))
	{
		$newrec{$copyable} = $args{$copyable};
	}
	$newrec{options} = ref($args{options}) eq "HASH"? $args{options} : {}; # make sure it's a hash

	# check freq and freq vs start/end
	my $freq = $args{frequency};
	return { error => "invalid frequency \"$freq\"!" }
	if (!defined $freq or $freq !~ /^(once|daily|weekly|monthly)$/);
	$newrec{frequency} = $args{frequency};

	my %parsedtimes;
	for my $check (qw(start end))
	{
		my $doesitparse = $freq eq "once"?
				( ($args{$check} =~ /^\d+(\.\d+)?$/)?
					$args{$check} :  func::parseDateTime($args{$check}) || func::getUnixTime($args{$check}) )
				: _abs_time(relative => $args{$check}, frequency => $freq);

		return { error => "invalid $check argument \"$args{$check}\" for frequency $freq!" }
		if (!$doesitparse);

		$parsedtimes{$check} = $doesitparse;
		# for one-offs let's store the parsed value
		# as it could have been a relative input like "now + 2 days"...
		if ($freq eq "once")
		{
			$newrec{$check} = $doesitparse;
		}
		else
		{
			$newrec{$check} = $args{$check};
		}
	}
	return { error => "invalid times, start is later than end!" }
	if ($freq eq "once" && $parsedtimes{start} >= $parsedtimes{end});

	# quick/rough sanity check of selectors
	$newrec{selector} = {};
	if (ref($args{selector}) eq "HASH")
	{
		for my $cat (qw(node config))
		{
			my $catsel = $args{selector}->{$cat};
			next if (ref($catsel) ne "HASH");

			for my $onesel (keys %$catsel)
			{
				# one string, or an array of strings
				return { error => "invalid selector content for \"$cat.$onesel\"!" }
				if (ref($catsel->{$onesel}) and ref($catsel->{$onesel}) ne "ARRAY");

				if (ref($catsel->{$onesel}) eq "ARRAY")
				{
					# fix up any holes if item N was deleted but N+1... exist
					$newrec{selector}->{$cat}->{$onesel} = [ grep( defined($_), @{$catsel->{$onesel}}) ];
				}
				elsif (defined $catsel->{$onesel})
				{
					$newrec{selector}->{$cat}->{$onesel} = $catsel->{$onesel};
				}
				else
				{
					delete $newrec{selector}->{$cat}->{$onesel};
				}
			}
		}
	}
	# inputs look good, lock and load!

	# except that loadtable doesn't allow file creation on the fly, only readfiletohash
	# which is much lowerlevel wrt arguments  :-/
	if (!existFile(dir => "conf", name => "Outages"))
	{
		writeTable(dir => "conf", name => "Outages", data => {});
	}
	my ($data, $fh) = loadTable(dir => "conf", name => "Outages", lock => 1);

	return { error => "failed to lock Outages file: $!" } if (!$fh);
	$data //= {};									# empty file is ok

	if ($op_create && ref($data->{$outid}))
	{
		close($fh);									# unlock
		return { error => "cannot create outage with id $outid: already existing!" };
	}
	$data->{$outid} = \%newrec;
	writeTable(dir => "conf", name => "Outages", handle => $fh, data => $data);

	func::audit_log(who => $meta->{user},
									what => ($op_create? "create_outage" : "update_outage"),
									where => $outid, how => "ok", details => $meta->{details}, when => undef);

	return { success => 1, id => $outid};
}

# reads an old-style outage.nmis and converts any current or future outages
# to the new format, then renames the file
# returns: undef if ok, error message otherwise
sub upgrade_outages
{
	my $C = loadConfTable();			# likely cached

	# we're clearly done if no conf/Outage.nmis exists
	my $oldoutagefile = func::getFileName(file => $C->{'<nmis_conf>'}."/Outage");
	return undef if (!-f $oldoutagefile);

	# load and lock the existing file
	my ($old, $fh) = loadTable( dir=>'conf', name=>'Outage', lock=>'true');
	for my $outagekey (keys %$old)
	{
		my $orec = $old->{$outagekey};
		next if ($orec->{end} < time);

		my $res = update_outage(frequency => "once",
														start => $orec->{start},
														end => $orec->{end},
														change_id => $orec->{change},
														selector => { node => { name => $orec->{node} } },
														meta => { user => ((getpwuid($<))[0]), # normally that's root
																			details => "automatic upgrade_outages" }		);
		if (!$res->{success})
		{
			close $fh;
			return "failed to convert outage: $res->{error}";
		}
	}

	# finally, rename the old file away
	if (!rename($oldoutagefile, "$oldoutagefile.disabled"))
	{
		my $problem = $!;
		close $fh;
		return "cannot rename $oldoutagefile: $problem";
	}
	close $fh;

	logMsg("INFO NMIS has successfully upgraded the Outage data structure, and the old configuration file was renamed to \"$oldoutagefile.disabled\".");

	return undef;
}

# removes past none-recurring outages after a configurable time
# returns: hashref, keys success/error
sub purge_outages
{
	my $C = loadConfTable();			# likely cached

	my $maxage = $C->{purge_outages_after} // 86400;
	return { success => 1, message => "Outage expiration is disabled." } if ($maxage <= 0); # 0 or negative? no purging

	my $data = loadTable(dir => "conf", name => "Outages")
			if (existFile(dir => "conf", name => "Outages")); # or we get lots of log noise
	return { success => 1, message => "No outages exist." } if !$data;

	my @problems;
	for my $outid (keys %$data)
	{
		my $thisoutage = $data->{$outid};
		next if ($thisoutage->{frequency} ne "once"
						 or $thisoutage->{end} >= time - $maxage);

		my $res = remove_outage(id => $outid, meta => {details => "purging expired past outage" });
		push @problems, "$outid: $res->{error}" if (!$res->{success}); # but let's continue
	}

	return (@problems? { error => join("\n", @problems) } : { success => 1 });
}


# take a relative/incomplete time and day specification and make into absolute timestamp
# args: relative (date + time, frequency-specific!),
# frequency (daily, weekly, monthly),
# base (optional, absolute base time; if not given now is used)
#
# the times are absolutified relative to now, so can be in the past or the future!
# returns: unix time if parseable, undef if not
sub _abs_time
{
	my (%args) = @_;

	my ($rel,$frequency) = @args{qw(relative frequency)};
	return undef if ($frequency !~ /^(once|daily|weekly|monthly)$/);

	my %wdlist = ("mon" => 1, "tue" => 2, "wed" => 3, "thu" => 4, "fri" => 5, "sat" => 6, "sun" => 7);
	my $timezone = "local";
	my $dt = $args{base}? DateTime->from_epoch(epoch => $args{base}, time_zone => $timezone)
			: DateTime->now(time_zone => $timezone);

	if ($frequency eq "weekly")
	{
		# format: weekday hh:mm(:ss)?, weekday is shortname!
		# pull off and mangle the weekday first
		if ($rel =~ s/^\s*(\S+)\s+//)
		{
			my $wd = lc(substr($1,0,3));
			return undef if !$wdlist{$wd};

			# truncate to week begin, then add X-1 days (monday is day 1!, but DT-weekstart is monday too...)
			$dt = $dt->truncate(to => "week")->add("days" => $wdlist{$wd}-1);
		}
	}
	elsif ($frequency eq "monthly")
	{
		# format: DayNum hh:mm(:ss)? DayNum==1 means first day of the month, DayNum==-1 means LAST day of the month etc.
		if ($rel =~ s/^(-?\d+)\s+//)
		{
			my $monthday = $1;
			$dt = $dt->truncate(to => "month");
			if ($monthday <= 0)
			{
				$dt->add(months => 1)->subtract(days => -$monthday);
			}
			else
			{
				eval { $dt->set(day => $monthday); };
				return undef if $@;
			}
		}
	}

	if ($frequency eq "daily")
	{
		$dt = $dt->truncate(to => "day");
	}
	else
	{
		return undef if !$dt;
	}

	# all inputs must have a time component
	# format: hh:mm(:ss)?, with 00:00 meaning day before and 24:00 day after

	if ($rel =~ /^\s*(\d+):(\d+)(:(\d+))?\s*$/)
	{
		my ($h,$m,$s) = ($1,$2,$4);
		$s ||= 0;

		return $dt->add(days => 1)->epoch
				if ($h == 24 and $m == 0 and $s == 0); # handle 24:00:00

		eval { $dt->set_hour($h)->set_minute($m)->set_second($s) };
		return $@? undef: $dt->epoch;
	}
	else
	{
		return undef; # hh:mm(:ss)? is required
	}
}

# advances (or reduces) timestamp by X intervals, based on the given frequency
# args: timestamp, frquency, count (default: +1)
# returns new timestamp
sub _prev_next_interval
{
	my (%args) = @_;
	my ($ts, $freq, $count) = @args{qw(timestamp frequency count)};

	my %freq2delta = ("daily" => { days => 1}, "weekly" => {weeks => 1},
										"monthly" => { months => 1 });
	return $ts if (!$freq or !$freq2delta{$freq} or (defined $count and !$count));
	$count ||= 1;

	my $timezone = 	"local";
	my $dt = 	DateTime->from_epoch(epoch => $ts, time_zone => $timezone);
	my %delta = %{$freq2delta{$freq}};

	if ($count < 0)
	{
		$delta{(keys %delta)[0]} = -$count; # only one key
		return $dt->subtract(%delta)->epoch;
	}
	else
	{
		$delta{(keys %delta)[0]} = $count;
		return $dt->add(%delta)->epoch;
	}
}

# remove existing outage
# args: id, optional meta (for audit logging, keys user, details)
# returns: hashref, keys success/error
sub remove_outage
{
	my (%args) = @_;
	my $id = $args{id};

	return { error => "cannot remove outage without id argument!" }
	if (!$id);

	my $meta = ref($args{meta}) eq "HASH"? $args{meta} : {};
	$meta->{user} ||= (getpwuid($<))[0];

	# lock and load the outages,
	# delete the indicated one,
	# save and unlock
	my ($data, $fh) = loadTable(dir => "conf", name => "Outages", lock => "true");
	return { error => "failed to lock Outage file: $!" } if (!$fh);
	$data //= {};

	delete $data->{$id};
	writeTable(dir => "conf", name => "Outages", handle => $fh, data => $data);

	func::audit_log(who => $meta->{user},
									what => "remove_outage",
									where => $id,
									how => "ok",
									details => $meta->{details},
									when => undef);

	return { success => 1};
}

# find outages, all or filtered
# args: filter (optional, hashref of outage properties => check values)
# note: filters are verbatim/passive/inert, ie. checked against the
# raw outage schedule - NOT evaluated with any nodes' nodeinfo/models etc!
#
# filter properties: id, description, change_id, frequency/start/end,
# options.nostats, selector.node.X, selector.config.Y - must be given in dotted form!
# filter check values can be: qr// or plain string/number.
# for array selectors one or more elems must match for the filter to match.
#
# returns: hashref of success/error, outages (=array of matching outages)
sub find_outages
{
	my (%args) = @_;
	my $filter = ref($args{filter}) eq "HASH"? $args{filter} : {};

	my $data = loadTable(dir => "conf", name => "Outages")
			if (existFile(dir => "conf", name => "Outages")); # or we get lots of log noise
	$data //= {};

	# unfiltered?
	return { success => 1, outages => [ values %$data ] }
	if (!keys %$filter);

	my @matches;
 SCRATCHMONKEY:
	for my $candidate (values %$data)
	{
		for my $filterprop (keys %$filter)
		{
			my ($have, $diag) = func::follow_dotted($candidate, $filterprop);
			next SCRATCHMONKEY if ($diag); # requested thing not present or wrong structure
			# none of the array elems match? (or the one and only thing doesn't?
			my @maybes = (ref($have) eq "ARRAY")? @$have: ($have);

			my $expected = $filter->{$filterprop};
			next SCRATCHMONKEY if ( List::Util::none { ref($expected) eq "Regexp"?
																										 ($_ =~ $expected) :
																										 ($_ eq $expected) } (@maybes) );
		}
		push @matches, $candidate;	# survived!
	}

	return { success => 1, outages => \@matches };
}

# find active/future/past outages for a given context,
# ie. one node and a time - or potential outages, if only
# given time.
#
# args: time (a unix timestamp, fractional is ok, required),
# node or uuid or a live and init'd sys object (optional),
#
# returns: hashref, with keys success/error, past, current, future: arrays (can be empty)
#
# current: outages that fully apply - these are amended with actual_start/actual_end unix TS,
#  and sorted by actual_start.
# past: past one-off (not recurring ones!) outages for this node
# future: future outages for this node, also with actual_start/actual_end (of the next instance),
#  sorted by actual_start.
sub check_outages
{
	my (%args) = @_;
	my $when = $args{time};
	my $S = $args{sys};						#  optional

	return { error => "cannot check outages without valid time argument!" }
	if (!$when or $when !~ /^\d+(\.d+)?$/);

	my $outagedata = loadTable(dir => "conf", name => "Outages")
			if (existFile(dir => "conf", name => "Outages"));
	$outagedata //= {};
	# no outages, no problem
	return { success => 1, future => [], past => [], current => [] }
	if (!keys %$outagedata);

	# get the data for selectors
	my $C = loadConfTable;	# cached

	my $who;
	if (ref($S) eq "Sys")	# that has all info ready...
	{
		$who = Clone::clone($S->ndcfg->{node}); # but let's not mess up sys datastructures
		$who->{nodeModel} = $S->ndinfo->{system}->{nodeModel};
	}
	elsif ($args{uuid} or $args{node})
	{
		my $LNT = loadLocalNodeTable();
		if ($args{uuid})
		{
			$who = (grep($_->{uuid} eq $args{uuid}, values %$LNT))[0]; # at most one
			return { error => "no node with uuid \"$args{uuid}\" exists!" } if (!$who);
			$who = Clone::clone($who);	# no polluting of lnt with nodeModel
		}
		else
		{
			$who = Clone::clone($LNT->{ $args{node} }); # no polluting of lnt with nodeModel
			return { error => "no node named \"$args{node}\" exists!" } if (!$who);
		}

		# also pull the node info for the nodeModel property
		my $ninfo = loadNodeInfoTable( $who->{name} );
		$who->{nodeModel} = $ninfo->{system}->{nodeModel};
	}

	my (@future,@past,@current);
	for my $outid (keys %$outagedata)
	{
		my $maybeout = $outagedata->{$outid};

		# let's check all selectors, iff there is something to check against
		if ($who)
		{
			my $rulematches = 1;
			for my $selcat (qw(config node))
			{
				next if (ref($maybeout->{selector}->{$selcat}) ne "HASH");

				for my $propname (keys %{$maybeout->{selector}->{$selcat}})
				{
					my $actual = ($selcat eq "config"?
												$C->{$propname} : $who->{$propname});

					# choices can be: regex, or fixed string, or array of fixed strings
					my $expected = $maybeout->{selector}->{$selcat}->{$propname};

					# list of precise matches
					if (ref($expected) eq "ARRAY")
					{
						$rulematches = 0 if (! List::Util::any { $actual eq $_ } @$expected);
					}
					# or a regex-like string
					elsif ($expected =~ m!^/(.*)/(i)?$!)
					{
						my ($re,$options) = ($1,$2);
						my $regex = ($options? qr{$re}i : qr{$re});
						$rulematches = 0 if ($actual !~ $regex);
					}
					# or a single precise match
					else
					{
						$rulematches = 0 if ($actual ne $expected);
					}

					last if (!$rulematches);
				}
				last if (!$rulematches);
			}
			# didn't survive all selector rules? note that no selectors === match
			next if (!$rulematches);
		}

		# how about the time?
		my $intime;
		if ($maybeout->{frequency} eq "once")
		{
			if ($when < $maybeout->{start})
			{
				push @future, { %$maybeout,
												actual_start => $maybeout->{start},
												actual_end => $maybeout->{end} }; # convenience only
			}
			elsif ($when >= $maybeout->{start} && $when <= $maybeout->{end})
			{
				push @current, { %$maybeout,
												 actual_start => $maybeout->{start},
												 actual_end => $maybeout->{end} }; # convenience only
				$intime = 1;
			}
			else # ie. > $maybeout->{end}
			{
				push @past, $maybeout;
			}
		}
		elsif ($maybeout->{frequency} =~ /^(daily|weekly|monthly)$/)
		{
			# absolute time is going to be 'near' when, but that's not quite good enough
			my $start = _abs_time(relative => $maybeout->{start},
														frequency => $maybeout->{frequency},
														base => $when);
			return { error => "outage \"$outid\" has invalid start \"$maybeout->{start}\"!" }
			if (!defined $start);

			my $end = _abs_time(relative => $maybeout->{end},
													frequency => $maybeout->{frequency},
													base => $when);
			return { error => "outage \"$outid\" has invalid end \"$maybeout->{end}\"!" }
			if (!defined $end);

			# start after end? (e.g. daily, start 1400, end 0200) -> start must go back one interval
			# (or end would have to go forward one)
			$start = _prev_next_interval(timestamp => $start, frequency => $maybeout->{frequency},
																	 count => -1) if ($start > $end);

			# advance or retreat until closest to when
			if ($when < $start && $when < $end) # retreat
			{
				while ($when < $start && $when < $end)
				{
					$start = _prev_next_interval(timestamp => $start,
																			 frequency => $maybeout->{frequency}, count => -1);
					$end = _prev_next_interval(timestamp => $end,
																		 frequency => $maybeout->{frequency}, count => -1);
				}
			}
			elsif ($when > $start && $when > $end) # advance
			{
				while ($when > $start && $when > $end)
				{
					$start = _prev_next_interval(timestamp => $start,
																			 frequency => $maybeout->{frequency}, count => 1);
					$end = _prev_next_interval(timestamp => $end,
																		 frequency => $maybeout->{frequency}, count => 1);
				}
			}

			# before both start and end is obviously future
			if ($when < $start)
			{
				push @future, { %$maybeout, actual_start => $start, actual_end => $end };
			}
			# but *after* both start and end is also future, just plus one or more repeat intervals
			elsif ($when > $end)
			{
				push @future, { %$maybeout,
												actual_start => _prev_next_interval(timestamp => $start,
																														frequency => $maybeout->{frequency},
																														count => 1),
												actual_end => _prev_next_interval(timestamp => $end,
																													frequency => $maybeout->{frequency},
																													count => 1),
				};
			}
			# and current is inbetween
			elsif ($when >= $start && $when <= $end)
			{
				push @current, { %$maybeout, actual_start => $start, actual_end => $end };
				$intime = 1;
			}
		}
		else
		{
			return { error => "outage \"$outid\" has invalid frequency!" };
		}

		next if (!$intime);
	}

	# sort current and future list by the actual start time
	@current = sort { $a->{actual_start} <=> $b->{actual_start} } @current;
	@future = sort { $a->{actual_start} <=> $b->{actual_start} } @future;

	return { success => 1,  past => \@past, current => \@current, future => \@future };
}

# compat wrapper around check_outages
# checks outage(s) for one node X and all nodes that X depends on
#
# fixme: why check dependency nodes at all? why only if those are down?
# and only if no direct future outages?
#
# args: node (name), time (unix ts), both required
# returns: nothing or ('current', FIRST current outage record)
# or ('pending', FIRST future outage)
#
sub outageCheck
{
	my %args = @_;

	my $node = $args{node};
	my $time = $args{time};

	my $nodeoutages = check_outages(node => $node, time => $time);
	if (!$nodeoutages->{success})
	{
		logMsg("ERROR failed to check $node outages: $nodeoutages->{error}");
		return;
	}

	if (@{$nodeoutages->{current}})
	{
		return ("current", $nodeoutages->{current}->[0]);
	}
	elsif (@{$nodeoutages->{future}})
	{
		return ("pending", $nodeoutages->{future}->[0]);
	}

	# if neither current nor future, check dependency nodes with
	# current outages and that are down
	my $NT = loadNodeTable();

	foreach my $nd ( split(/,/,$NT->{$node}{depend}) )
	{
		# ignore nonexistent stuff, defaults and circular self-dependencies
		next if ($nd =~ m!^(N/A|$node)?$!);
		my $depoutages = check_outages(node => $nd, time => $time);
		if (!$depoutages->{success})
		{
			logMsg("ERROR failed to check $nd outages: $depoutages->{error}");
			return;
		}
		if (@{$depoutages->{current}})
		{
			# check if this node is down
			my $NI = loadNodeInfoTable($nd);
			if (getbool($NI->{system}{nodedown}))
			{
				return ("current", $depoutages->{current}->[0]);
			}
		}
	}
	return;
}

# small translator from event level to priority: header for email
sub eventToSMTPPri {
	my $level = shift;
	# More granularity might be possible there are 5 numbers but
	# can only find word to number mappings for L, N, H
	if ( $level eq "Normal" ) { return "Normal" }
	elsif ( $level eq "Warning" ) { return "Normal" }
	elsif ( $level eq "Minor" ) { return "Normal" }
	elsif ( $level eq "Major" ) { return "High" }
	elsif ( $level eq "Critical" ) { return "High" }
	elsif ( $level eq "Fatal" ) { return "High" }
	elsif ( $level eq "Disaster" ) { return "High" }
	elsif ( $level eq "Catastrophic" ) { return "High" }
	elsif ( $level eq "Unknown" ) { return "Low" }
	else
	{
		return "Normal";
	}
}

# test the dutytime of the given contact.
# return true if OK to notify
# expect a reference to %contact_table, and a contact name to lookup
sub dutyTime {
	my ($table , $contact) = @_;
	my $today;
	my $days;
	my $start_time;
	my $finish_time;

	if ( $$table{$contact}{DutyTime} ) {
	    # dutytime has some values, so assume TZ offset to localtime has as well
		my @ltime = localtime( time() + ($$table{$contact}{TimeZone}*60*60));
		my $out = sprintf("Using corrected time %s for Contact:$contact, localtime:%s, offset:$$table{$contact}{TimeZone}", scalar localtime(time()+($$table{$contact}{TimeZone}*60*60)), scalar localtime());
		dbg($out);

		( $start_time, $finish_time, $days) = split /:/, $$table{$contact}{DutyTime}, 3;
		$today = ("Sun","Mon","Tue","Wed","Thu","Fri","Sat")[$ltime[6]];
		if ( $days =~ /$today/i ) {
			if ( $ltime[2] >= $start_time && $ltime[2] < $finish_time ) {
				dbg("returning success on dutytime test for $contact");
				return 1;
			}
			elsif ( $finish_time < $start_time ) {
				if ( $ltime[2] >= $start_time || $ltime[2] < $finish_time ) {
					dbg("returning success on dutytime test for $contact");
					return 1;
				}
			}
		}
	}
	# dutytime blank or undefined so treat as 24x7 days a week..
	else {
		dbg("No dutytime defined - returning success assuming $contact is 24x7");
		return 1;
	}
	dbg("returning fail on dutytime test for $contact");
	return 0;		# dutytime was valid, but no timezone match, return false.
}


# quick dns lookup for names
# args: name
# returns: list of addresses (or empty array)
sub resolve_dns_name
{
	my ($lookup) = @_;
	my @results;

	# full ipv6 support works only with newer socket module
	my ($err,@possibles) = Socket::getaddrinfo($lookup,'',
																						 {socktype => SOCK_RAW});
	return () if ($err);

	for my $address (@possibles)
	{
		my ($err,$ipaddr) = Socket::getnameinfo(
			$address->{addr},
			Socket::NI_NUMERICHOST(),
			Socket::NIx_NOSERV());
		push @results, $ipaddr if (!$err and $ipaddr ne $lookup); # suppress any nop results
	}
	return @results;
}

# wrapper around resolve_dns_name,
# returns the _first_ available ip _v4_ address or undef
sub resolveDNStoAddr
{
	my ($name) = @_;

	my @addrs = resolve_dns_name($name);
	my @v4 = grep(/^\d+.\d+.\d+\.\d+$/, @addrs);

	return $v4[0];
}

# produce clickable graph and return html that can be pasted onto a page
# rrd graph is created by this function and cached on disk
#
# args: node/group, intf/item, server, graphtype, width, height (all required),
#  start, end (optional),
#  only_link (optional, default: 0, if set ONLY the href for the graph is returned)
# returns: html or link/href value
sub htmlGraph
{
	my %args = @_;

	my $C = loadConfTable();

	my $graphtype = $args{graphtype};
	my $group = $args{group};
	my $node = $args{node};
	my $intf = $args{intf};
	my $item  = $args{item};
	my $server = $args{server};
	my $width = $args{width}; # graph size
	my $height = $args{height};
	my $omit_fluff = getbool($args{only_link}); # return wrapped <a> etc. or just the href?

	my $urlsafenode = uri_escape($node);
	my $urlsafegroup = uri_escape($group);
	my $urlsafeintf = uri_escape($intf);
	my $urlsafeitem = uri_escape($item);

	my $target = $node || $group; # only used for js/widget linkage
	my $clickurl = "$C->{'node'}?conf=$C->{conf}&act=network_graph_view&graphtype=$graphtype&group=$urlsafegroup&intf=$urlsafeintf&item=$urlsafeitem&server=$server&node=$urlsafenode";

	my $time = time();
	my $graphlength = ( $C->{graph_unit} eq "days" )?
			86400 * $C->{graph_amount} : 3600 * $C->{graph_amount};
	my $start = $args{start} || time-$graphlength;
	my $end = $args{end} || $time;

	# where to put the graph file? let's use htdocs/cache, that's web-accessible
	my $cachedir = $C->{'web_root'}."/cache";
	createDir($cachedir) if (!-d $cachedir);

	# we need a time-invariant, short and safe file name component,
	# which also must incorporate a server-specific bit of secret sauce
	# that an external party does not have access to (to eliminate guessing)
	my $graphfile_prefix = Digest::MD5::md5_hex(
		join("__",
				 $C->{auth_web_key},
				 $C->{conf}, # fixme: needed? useful? relevant?
				 $group, $node, $intf, $item,
				 $graphtype,
				 $server, # fixme: needed?
				 $width, $height));

	# do we want to reuse an existing, 'new enough' graph?
	opendir(D, $cachedir);
	my @recyclables = grep(/^$graphfile_prefix/, readdir(D));
	closedir(D);

	my $graphfilename;
	my $cachefilemaxage = $C->{graph_cache_maxage} // 60;

	for my $maybe (sort { $b cmp $a } @recyclables)
	{
		next if ($maybe !~ /^\S+_(\d+)_(\d+)\.png$/); # should be impossible
		my ($otherstart, $otherend) = ($1,$2);

		# let's accept anything newer than 60 seconds as good enough
		my $deltastart = $start - $otherstart;
		$deltastart *= -1 if ($deltastart < 0);
		my $deltaend = $end - $otherend;
		$deltaend *= -1 if ($deltaend < 0);

		if ($deltastart <= $cachefilemaxage && $deltaend <= $cachefilemaxage)
		{
			$graphfilename = $maybe;
			dbg("reusing cached graph $maybe for $graphtype, node $node: requested period off by ".($start-$otherstart)." seconds");

			last;
		}
	}

	# nothing useful in the cache? then generate a new graph
	if (!$graphfilename)
	{
		$graphfilename = $graphfile_prefix."_${start}_${end}.png";
		dbg("graphing args for new graph: node=$node, group=$group, graphtype=$graphtype, intf=$intf, item=$item, server=$server, start=$start, end=$end, width=$width, height=$height, filename=$cachedir/$graphfilename");

		my $target = "$cachedir/$graphfilename";
		my ($error, $graphret) = NMIS::RRDdraw::draw(node => $node,
																								 group => $group,
																								 graphtype => $graphtype,
																								 intf => $intf,
																								 item => $item,
																								 server => $server,
																								 start => $start,
																								 end =>  $end,
																								 width => $width,
																								 height => $height,
																								 filename => $target);
		return qq|<p>Error: $error</p>| if ($error);
		func::setFileProt($target);	# to make the selftest happy...
	}

	# return just the href? or html?
	return $omit_fluff? "$C->{'<url_base>'}/cache/$graphfilename"
			: qq|<a target="Graph-$target" onClick="viewwndw(\'$target\',\'$clickurl\',$C->{win_width},$C->{win_height})"><img alt='Network Info' src="$C->{'<url_base>'}/cache/$graphfilename"></img></a>|;
}

# args: user, node, system, refresh, widget, au (object),
# conf (=name of config for links)
# returns: html as array of lines
sub createHrButtons
{
	my %args = @_;
	my $user = $args{user};
	my $node = $args{node};
	my $S = $args{system};
	my $refresh = $args{refresh};
	my $widget = $args{widget};
	my $AU = $args{AU};
	my $confname = $args{conf};

	return "" if (!$node);
	$refresh = "false" if (!getbool($refresh));

	my @out;

	my $NI = loadNodeInfoTable($node);
	my $C = loadConfTable();

	return unless $AU->InGroup($NI->{system}{group});

	my $server = getbool($C->{server_master}) ? '' : $NI->{system}{server};
	my $urlsafenode = uri_escape($node);

	push @out, "<table class='table'><tr>\n";

	# provide link back to the main dashboard if not in widget mode
	push @out, CGI::td({class=>"header litehead"}, CGI::a({class=>"wht", href=>$C->{'nmis'}."?conf=$confname"}, "NMIS $NMIS::VERSION"))
			if (!getbool($widget));

	push @out, CGI::td({class=>'header litehead'},'Node ',
			CGI::a({class=>'wht',href=>"network.pl?conf=$confname&act=network_node_view&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},$node));

	if (scalar keys %{$NI->{module}}) {
		push @out, CGI::td({class=>'header litehead'},
			CGI::a({class=>'wht',href=>"network.pl?conf=$confname&act=network_module_view&node=$urlsafenode&server=$server"},"modules"));
	}

	if ($S->getTypeInstances(graphtype => 'service', section => 'service')) {
		push @out, CGI::td({class=>'header litehead'},
			CGI::a({class=>'wht',href=>"network.pl?conf=$confname&act=network_service_view&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"services"));
	}

	if (getbool($NI->{system}{collect})) {
		push @out, CGI::td({class=>'header litehead'},
				CGI::a({class=>'wht',href=>"network.pl?conf=$confname&act=network_status_view&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"status"))
				if defined $NI->{status} and defined $C->{display_status_summary}
		and getbool($C->{display_status_summary});
		push @out, CGI::td({class=>'header litehead'},
				CGI::a({class=>'wht',href=>"network.pl?conf=$confname&act=network_interface_view_all&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"interfaces"))
				if (defined $S->{mdl}{interface});
		push @out, CGI::td({class=>'header litehead'},
				CGI::a({class=>'wht',href=>"network.pl?conf=$confname&act=network_interface_view_act&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"active intf"))
				if defined $S->{mdl}{interface};
		if (defined $S->{mdl}{interface} && ref($NI->{interface}) eq "HASH" && %{$NI->{interface}})
		{
			push @out, CGI::td({class=>'header litehead'},
				CGI::a({class=>'wht',href=>"network.pl?conf=$confname&act=network_port_view&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"ports"));
		}
		if (ref($NI->{storage}) eq "HASH" && %{$NI->{storage}})
		{
			push @out, CGI::td({class=>'header litehead'},
				CGI::a({class=>'wht',href=>"network.pl?conf=$confname&act=network_storage_view&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"storage"));
		}

		# adding services list support, but hide the tab if the snmp service collection isn't working
		if (defined $NI->{services} && keys %{$NI->{services}}) {
					push @out, CGI::td({class=>'header litehead'},
				CGI::a({class=>'wht',href=>"network.pl?conf=$confname&act=network_service_list&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"service list"));
		}

		if ($S->getTypeInstances(graphtype => "hrsmpcpu")) {
					push @out, CGI::td({class=>'header litehead'},
				CGI::a({class=>'wht',href=>"network.pl?conf=$confname&act=network_cpu_list&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"cpu list"));
		}

		# let's show the possibly many systemhealth items in a dropdown menu
		if ( defined $S->{mdl}{systemHealth}{sys} )
		{
    	my @systemHealth = split(",",$S->{mdl}{systemHealth}{sections});
			push @out, "<td class='header litehead'><ul class='jd_menu hr_menu'><li>System Health &#x25BE<ul>";
			foreach my $sysHealth (@systemHealth)
			{
				# don't show spurious blank entries
				if (ref($NI->{$sysHealth}) eq "HASH" and keys(%{$NI->{$sysHealth}}))
				{
					push @out, CGI::li(CGI::a({ class=>'wht',  href=>"network.pl?conf=$confname&act=network_system_health_view&section=$sysHealth&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"}, $sysHealth));
				}
			}
			push @out, "</ul></li></ul></td>";
		}

		### 2012-12-13 keiths, adding generic temp support
		if ($NI->{env_temp} ne '' or $NI->{env_temp} ne '') {
			push @out, CGI::td({class=>'header litehead'},
				CGI::a({class=>'wht',href=>"network.pl?conf=$confname&act=network_environment_view&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"environment"));
		}
		#2011-11-11 Integrating changes from Kai-Uwe Poenisch
		if ($NI->{akcp_temp} ne '' or $NI->{akcp_hum} ne '') {
			push @out, CGI::td({class=>'header litehead'},
				CGI::a({class=>'wht',href=>"network.pl?conf=$confname&act=network_environment_view&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"environment"));
		}
		#2011-11-11 Integrating changes from Kai-Uwe Poenisch
		if ($NI->{cssgroup} ne '') {
			push @out, CGI::td({class=>'header litehead'},
				CGI::a({class=>'wht',href=>"network.pl?conf=$confname&act=network_cssgroup_view&node=$urlsafenode&refresh=false&server=$server"},"Group"));
		}
		#2011-11-11 Integrating changes from Kai-Uwe Poenisch
 		if ($NI->{csscontent} ne '') {
			push @out, CGI::td({class=>'header litehead'},
				CGI::a({class=>'wht',href=>"network.pl?conf=$confname&act=network_csscontent_view&node=$urlsafenode&refresh=false&server=$server"},"Content"));
		}
	}

	push @out, CGI::td({class=>'header litehead'},
			CGI::a({class=>'wht',href=>"events.pl?conf=$confname&act=event_table_view&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"events"));
	push @out, CGI::td({class=>'header litehead'},
			CGI::a({class=>'wht',href=>"outages.pl?conf=$confname&act=outage_table_view&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"outage"));


	# and let's combine these in a 'diagnostic' menu as well
	push @out, "<td class='header litehead'><ul class='jd_menu hr_menu'><li>Diagnostic &#x25BE<ul>";

	# drill-in for the node's collect/update time
	push @out, CGI::li(CGI::a({class=>"wht",
														 href=> "$C->{'<cgi_url_base>'}/node.pl?conf=$confname&act=network_graph_view&widget=false&node=$urlsafenode&graphtype=polltime",
																 target=>"_blank"},
														"Collect/Update Runtime"));

	push @out, CGI::li(CGI::a({class=>'wht',
														 href=>"telnet://$NI->{system}{host}",target=>'_blank'},"telnet"))
			if (getbool($C->{view_telnet}));

	if (getbool($C->{view_ssh})) {
		my $ssh_url = $C->{ssh_url} ? $C->{ssh_url} : "ssh://";
		my $ssh_port = $C->{ssh_port} ? ":$C->{ssh_port}" : "";
		push @out, CGI::li(CGI::a({class=>'wht',href=>"$ssh_url$NI->{system}{host}$ssh_port",
										 target=>'_blank'},"ssh"));
	}

	push @out, CGI::li(CGI::a({class=>'wht',
									 href=>"tools.pl?conf=$confname&act=tool_system_ping&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"ping"))
			if getbool($C->{view_ping});
	push @out, CGI::li(CGI::a({class=>'wht',
									 href=>"tools.pl?conf=$confname&act=tool_system_trace&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"trace"))
			if getbool($C->{view_trace});
	push @out, CGI::li(CGI::a({class=>'wht',
									 href=>"tools.pl?conf=$confname&act=tool_system_mtr&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"mtr"))
			if getbool($C->{view_mtr});

	push @out, CGI::li(CGI::a({class=>'wht',
									 href=>"tools.pl?conf=$confname&act=tool_system_lft&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"lft"))
			if getbool($C->{view_lft});

	push @out, CGI::li(CGI::a({class=>'wht',
									 href=>"http://$NI->{system}{host}",target=>'_blank'},"http"))
			if getbool($NI->{system}{webserver});
	# end of diagnostic menu
	push @out, "</ul></li></ul></td>";

	if ($NI->{system}{server} eq $C->{server_name}) {
		my $location_field_name = "sysLocation";
		if ( defined $C->{location_field_name} and $C->{location_field_name} ne "" ) {
			$location_field_name = $C->{location_field_name};
		}

		push @out, CGI::td({class=>'header litehead'},
				CGI::a({class=>'wht',href=>"tables.pl?conf=$confname&act=config_table_show&table=Contacts&key=".uri_escape($NI->{system}{sysContact})."&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"contact"))
					if $NI->{system}{sysContact} ne '';
		push @out, CGI::td({class=>'header litehead'},
				CGI::a({class=>'wht',href=>"tables.pl?conf=$confname&act=config_table_show&table=Locations&key=".uri_escape($NI->{system}{$location_field_name})."&node=$urlsafenode&refresh=$refresh&widget=$widget&server=$server"},"location"))
					if $NI->{system}{$location_field_name} ne '';
	}

	push @out, "</tr></table>";

	return @out;
}

sub loadPortalCode {
	my %args = @_;
	my $conf = $args{conf};
	my $C =	loadConfTable();

	$conf = $C->{'conf'} if not $conf;

	my $portalCode;
	if  ( -f getFileName(file => "$C->{'<nmis_conf>'}/Portal") ) {
		# portal menu of nodes or clients to link to.
		my $P = loadTable(dir=>'conf',name=>"Portal");

		my $portalOption;

		foreach my $p ( sort {$a <=> $b} keys %{$P} ) {
			# If the link is part of NMIS, append the config
			my $selected;

			if ( $P->{$p}{Link} =~ /cgi-nmis8/ ) {
				$P->{$p}{Link} .= "?conf=$conf";
			}

			if ( $ENV{SCRIPT_NAME} =~ /nmiscgi/ and $P->{$p}{Link} =~ /nmiscgi/ and $P->{$p}{Name} =~ /NMIS8/ ) {
				$selected = " selected=\"$P->{$p}{Name}\"";
			}
			elsif ( $ENV{SCRIPT_NAME} =~ /maps/ and $P->{$p}{Name} =~ /Map/ ) {
				$selected = " selected=\"$P->{$p}{Name}\"";
			}
			elsif ( $ENV{SCRIPT_NAME} =~ /ipsla/ and $P->{$p}{Name} eq "IPSLA" ) {
				$selected = " selected=\"$P->{$p}{Name}\"";
			}
			$portalOption .= qq|<option value="$P->{$p}{Link}"$selected>$P->{$p}{Name}</option>\n|;
		}


		$portalCode = qq|
				<div class="left">
					<form id="viewpoint">
						<select name="viewselect" onchange="window.open(this.options[this.selectedIndex].value);" size="1">
							$portalOption
						</select>
					</form>
				</div>|;

	}
	return $portalCode;
}

sub loadServerCode {
	my %args = @_;
	my $conf = $args{conf};
	my $C = loadConfTable();

	$conf = $C->{'conf'} if not $conf;

	my $serverCode;
	if  ( -f getFileName(file => "$C->{'<nmis_conf>'}/Servers") ) {
		# portal menu of nodes or clients to link to.
		my $ST = loadServersTable();

		my $serverOption;

		$serverOption .= qq|<option value="$ENV{SCRIPT_NAME}" selected="NMIS Servers">NMIS Servers</option>\n|;

		foreach my $srv ( sort {$ST->{$a}{name} cmp $ST->{$b}{name}} keys %{$ST} ) {
			## don't process server localhost for opHA2
			next if $srv eq "localhost";

			# If the link is part of NMIS, append the config
			$serverOption .= qq|<option value="$ST->{$srv}{portal_protocol}://$ST->{$srv}{portal_host}:$ST->{$srv}{portal_port}$ST->{$srv}{cgi_url_base}/nmiscgi.pl?conf=$ST->{$srv}{config}">$ST->{$srv}{name}</option>\n|;
		}


		$serverCode = qq|
				<div class="left">
					<form id="serverSelect">
						<select name="serverOption" onchange="window.open(this.options[this.selectedIndex].value);" size="1">
							$serverOption
						</select>
					</form>
				</div>|;

	}
	return $serverCode;
}

sub loadTenantCode {
	my %args = @_;
	my $conf = $args{conf};
	my $C = loadConfTable();

	$conf = $C->{'conf'} if not $conf;

	my $tenantCode;
	if  ( -f getFileName(file => "$C->{'<nmis_conf>'}/Tenants") ) {
		# portal menu of nodes or clients to link to.
		my $MT = loadTable(dir=>'conf',name=>"Tenants");

		my $tenantOption;

		$tenantOption .= qq|<option value="$ENV{SCRIPT_NAME}" selected="NMIS Tenants">NMIS Tenants</option>\n|;

		foreach my $t ( sort {$MT->{$a}{Name} cmp $MT->{$b}{Name}} keys %{$MT} ) {
			# If the link is part of NMIS, append the config

			$tenantOption .= qq|<option value="?conf=$MT->{$t}{Config}">$MT->{$t}{Name}</option>\n|;
		}


		$tenantCode = qq|
				<div class="left">
					<form id="serverSelect">
						<select name="serverOption" onchange="window.open(this.options[this.selectedIndex].value);" size="1">
							$tenantOption
						</select>
					</form>
				</div>|;

	}
	return $tenantCode;
}

sub startNmisPage {
	my %args = @_;
	my $title = $args{title};
	my $refresh = $args{refresh};
	$title = "NMIS by Opmantek" if ($title eq "");
	$refresh = 86400 if ($refresh eq "");

	my $C = loadConfTable();

	print qq
|<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "http://www.w3.org/TR/html4/loose.dtd">
<html>
  <head>
    <title>$title</title>
    <meta http-equiv="Content-Type" content="text/html; charset=iso-8859-1" />
    <meta http-equiv="Pragma" content="no-cache" />
    <meta http-equiv="Cache-Control" content="no-cache, no-store" />
    <meta http-equiv="Expires" content="-1" />
    <meta http-equiv="Robots" content="none" />
    <meta http-equiv="Googlebot" content="noarchive" />
    <link type="image/x-icon" rel="shortcut icon" href="$C->{'nmis_favicon'}" />
    <link type="text/css" rel="stylesheet" href="$C->{'jquery_ui_css'}" />
    <link type="text/css" rel="stylesheet" href="$C->{'jquery_jdmenu_css'}" />
    <link type="text/css" rel="stylesheet" href="$C->{'styles'}" />
    <script src="$C->{'jquery'}" type="text/javascript"></script>
    <script src="$C->{'jquery_ui'}" type="text/javascript"></script>
    <script src="$C->{'jquery_bgiframe'}" type="text/javascript"></script>
    <script src="$C->{'jquery_positionby'}" type="text/javascript"></script>
    <script src="$C->{'jquery_jdmenu'}" type="text/javascript"></script>
    <script src="$C->{'calendar'}" type="text/javascript"></script>
    <script src="$C->{'calendar_setup'}" type="text/javascript"></script>
    <script src="$C->{'jquery_ba_dotimeout'}" type="text/javascript"></script>
    <script src="$C->{'nmis_common'}" type="text/javascript"></script>
  </head>
  <body>
|;
	return 1;
}

sub pageStart {
	my %args = @_;
	my $refresh = $args{refresh};
	my $title = $args{title};
	my $jscript = $args{jscript};
	$jscript = getJavaScript() if ($jscript eq "");
	$title = "NMIS by Opmantek" if ($title eq "");

	my $C = loadConfTable();

	print qq
|<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "http://www.w3.org/TR/html4/loose.dtd">
<html>
  <head>
	<title>$title</title>|,
	(defined($refresh) && $refresh > 0 ?
	 qq|<meta http-equiv="refresh" content="$refresh" />\n| : ""),

	qq|<meta http-equiv="Content-Type" content="text/html; charset=iso-8859-1" />
    <meta http-equiv="Pragma" content="no-cache" />
    <meta http-equiv="Cache-Control" content="no-cache, no-store" />
    <meta http-equiv="Expires" content="-1" />
    <meta http-equiv="Robots" content="none" />
    <meta http-equiv="Googlebot" content="noarchive" />
    <link type="image/x-icon" rel="shortcut icon" href="$C->{'nmis_favicon'}" />
    <link type="text/css" rel="stylesheet" href="$C->{'jquery_ui_css'}" />
    <link type="text/css" rel="stylesheet" href="$C->{'jquery_jdmenu_css'}" />
    <link type="text/css" rel="stylesheet" href="$C->{'styles'}" />
    <script src="$C->{'jquery'}" type="text/javascript"></script>
    <script>
$jscript
</script>
  </head>
  <body>
|;
}


sub pageStartJscript {
	my %args = @_;
	my $title = $args{title};
	my $refresh = $args{refresh};
	$title = "NMIS by Opmantek" if ($title eq "");

	my $C = loadConfTable();

	print qq
|<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "http://www.w3.org/TR/html4/loose.dtd">
<html>
  <head>
	<title>$title</title>|,
	(defined($refresh) && $refresh > 0?
	 qq|<meta http-equiv="refresh" content="$refresh" />\n| : "" ),

  qq|<meta http-equiv="Content-Type" content="text/html; charset=iso-8859-1" />
    <meta http-equiv="Pragma" content="no-cache" />
    <meta http-equiv="Cache-Control" content="no-cache, no-store" />
    <meta http-equiv="Expires" content="-1" />
    <meta http-equiv="Robots" content="none" />
    <meta http-equiv="Googlebot" content="noarchive" />
    <link type="image/x-icon" rel="shortcut icon" href="$C->{'nmis_favicon'}" />
    <link type="text/css" rel="stylesheet" href="$C->{'jquery_ui_css'}" />
    <link type="text/css" rel="stylesheet" href="$C->{'jquery_jdmenu_css'}" />
    <link type="text/css" rel="stylesheet" href="$C->{'styles'}" />
    <script src="$C->{'jquery'}" type="text/javascript"></script>
    <script src="$C->{'jquery_ui'}" type="text/javascript"></script>
    <script src="$C->{'jquery_bgiframe'}" type="text/javascript"></script>
    <script src="$C->{'jquery_positionby'}" type="text/javascript"></script>
    <script src="$C->{'jquery_jdmenu'}" type="text/javascript"></script>
    <script src="$C->{'calendar'}" type="text/javascript"></script>
    <script src="$C->{'calendar_setup'}" type="text/javascript"></script>
    <script src="$C->{'jquery_ba_dotimeout'}" type="text/javascript"></script>
    <script src="$C->{'nmis_common'}" type="text/javascript"></script>
  </head>
  <body>
|;
	return 1;
}

sub pageEnd {
	print "</body></html>";
}


sub getJavaScript {
	my $jscript = <<JS_END;
function viewwndw(wndw,url,width,height)
{
	var attrib = "scrollbars=yes,resizable=yes,width=" + width + ",height=" + height;
	ViewWindow = window.open(url,wndw,attrib);
	ViewWindow.focus();
};
JS_END

	return $jscript;
}

### 2012-03-09 keiths, summary sub to avoid changing much other code
sub requestServer {
	return 0;
}

# Load and organize the CBQoS meta-data, used by both rrddraw.pl and node.pl
# inputs: a sys object, an index and a graphtype
# returns ref to sorted list of names, ref to hash of description/bandwidth/color/index/section
# this function is not exported on purpose, to reduce namespace clashes.
sub loadCBQoS
{
	my %args = @_;
	my $S = $args{sys};
	my $index = $args{index};
	my $graphtype = $args{graphtype};

	my $NI = $S->ndinfo;
	my $CB = $S->cbinfo;
	my $M = $S->mdl;
	my $node = $NI->{name};

	my ($PMName,  @CMNames, %CBQosValues , @CBQosNames);

	# define line/area colors of the graph
	my @colors = ("3300ff", "33cc33", "ff9900", "660099",
								"ff66ff", "ff3333", "660000", "0099CC",
								"0033cc", "4B0082","00FF00", "FF4500",
								"008080","BA55D3","1E90FF",  "cc00cc");

	my $direction = $graphtype eq "cbqos-in" ? "in" : "out" ;

	# in the cisco case we have the classmap as basis;
	# for huawei this info comes from the QualityOfServiceStat section
	# which is indexed (and collected+saved) per qos stat entry, NOT interface!
	if (exists $NI->{QualityOfServiceStat})
	{
		my $huaweiqos = $NI->{QualityOfServiceStat};
		for my $k (keys %{$huaweiqos})
		{
			next if ($huaweiqos->{$k}->{ifIndex} != $index or $huaweiqos->{$k}->{Direction} !~ /^$direction/);
			my $CMName = $huaweiqos->{$k}->{ClassifierName};
			push @CMNames, $CMName;
			$PMName = $huaweiqos->{$k}->{Direction}; # there are no policy map names in huawei's qos

			# huawei devices don't expose descriptions or (easily accessible) bw limits
			$CBQosValues{$index.$CMName} = { CfgType => "Bandwidth", CfgRate => undef,
																			 CfgIndex => $k, CfgItem =>  undef,
																			 CfgUnique => $k, # index+cmname is not unique, doesn't cover inbound/outbound - this does.
																			 CfgSection => "QualityOfServiceStat",
																			 # ds names: bytes for in, out, and drop (aka prepolicy postpolicy drop in cisco parlance),
																			 # then packets and nobufdroppkt (which huawei doesn't have)
																			 CfgDSNames => [qw(MatchedBytes MatchedPassBytes MatchedDropBytes MatchedPackets MatchedPassPackets MatchedDropPackets),undef],
			};
		}
	}
	else													# the cisco case
	{
		$PMName = $CB->{$index}{$direction}{PolicyMap}{Name};

		foreach my $k (keys %{$CB->{$index}{$direction}{ClassMap}}) {
			my $CMName = $CB->{$index}{$direction}{ClassMap}{$k}{Name};
			push @CMNames , $CMName if $CMName ne "";

			$CBQosValues{$index.$CMName} = { CfgType => $CB->{$index}{$direction}{ClassMap}{$k}{'BW'}{'Descr'},
																			 CfgRate => $CB->{$index}{$direction}{ClassMap}{$k}{'BW'}{'Value'},
																			 CfgIndex => $index, CfgItem => undef,
																			 CfgUnique => $k,  # index+cmname is not unique, doesn't cover inbound/outbound - this does.
																			 CfgSection => $graphtype,
																			 CfgDSNames => [qw(PrePolicyByte PostPolicyByte DropByte PrePolicyPkt),
																											undef,"DropPkt", "NoBufDropPkt"]};
		}
	}

	# order the buttons of the classmap names for the Web page
	@CMNames = sort {uc($a) cmp uc($b)} @CMNames;

	my @qNames;
	my @confNames = split(',', $M->{node}{cbqos}{order_CM_buttons});
	foreach my $Name (@confNames) {
		for (my $i=0; $i<=$#CMNames; $i++) {
			if ($Name eq $CMNames[$i] ) {
				push @qNames, $CMNames[$i] ; # move entry
				splice (@CMNames,$i,1);
				last;
			}
		}
	}

	@CBQosNames = ($PMName,@qNames,@CMNames); #policy name, classmap names sorted, classmap names unsorted
	if ($#CBQosNames) {
		# colors of the graph in the same order
		for my $i (1..$#CBQosNames) {
			if ($i < $#colors ) {
				$CBQosValues{"${index}$CBQosNames[$i]"}{'Color'} = $colors[$i-1];
			} else {
				$CBQosValues{"${index}$CBQosNames[$i]"}{'Color'} = "000000";
			}
		}
	}

	return \(@CBQosNames,%CBQosValues);
} # end loadCBQos

# all event handling routines follow below


# small helper that translates event data into a severity level
# args: event, role.
# returns: severity level, color
# fixme: only used for group status summary display! actual event priorities come from the model
sub eventLevel {
	my ($event, $role) = @_;

	my ($event_level, $event_color);

	my $C = loadConfTable();			# cached, mostly nop

	# the config now has a structure for xlat between roletype and severities for node down/other events
	my $rt2sev = $C->{severity_by_roletype};
	$rt2sev = { default => [ "Major", "Minor" ] } if (ref($rt2sev) ne "HASH" or !keys %$rt2sev);

	if ( $event eq 'Node Down' )
	{
		$event_level = ref($rt2sev->{$role}) eq "ARRAY"? $rt2sev->{$role}->[0] :
				ref($rt2sev->{default}) eq "ARRAY"? $rt2sev->{default}->[0] : "Major";
	}
	elsif ( $event =~ /up/i )
	{
		$event_level = "Normal";
	}
	else
	{
		$event_level = ref($rt2sev->{$role}) eq "ARRAY"? $rt2sev->{$role}->[1] :
				ref($rt2sev->{default}) eq "ARRAY"? $rt2sev->{default}->[1] : "Major";
	}
	$event_level = "Major" if ($event_level !~ /^(fatal|critical|major|minor|warning|normal)$/i); 	# last-ditch fallback
	$event_color = eventColor($event_level);

	return ($event_level,$event_color);
}

# this function checks if a particular event exists
# in the list of current event, NOT the history list!
#
# args: node, event(name), element (element may be missing)
# returns event file name if present, 0/undef otherwise
sub eventExist
{
	my ($node, $eventname, $element) = @_;

	my $efn = event_to_filename(event => {
			node => $node,
			event => $eventname,
			element => $element
		}, category => "current"
	);
	return ($efn and -f $efn)? $efn : 0;
}

# returns the detailed event record for the given CURRENT event
# args: node, event(name), element OR filename
# returns event hash or undef
sub eventLoad
{
	my (%args) = @_;

	my $efn = $args{filename}
	|| event_to_filename( event => { node => $args{node},
																	 event => $args{event},
																	 element => $args{element} },
												category => "current" );
	return undef if (!$efn or !-f $efn);
	if (!open(F, "$efn"))
	{
		logMsg("ERROR cannot open event file $efn: $!");
		return undef;
	}
	my $erec = eval { decode_json(join("", <F>)) };
	close(F);
	if (ref($erec) ne "HASH" or $@)
	{
		logMsg("ERROR event file $efn has malformed data: $@");
		return undef;
	}

	return $erec;
}

# deletes ONE event, does NOT (event-)log anything
# args: event (=record suitably filled in to find the file)
# the event file is parked in the history subdir, iff possible and allowed to
# returns undef if ok, error message otherwise
sub eventDelete
{
	my (%args) = @_;

	my $C = loadConfTable();

	return "Cannot remove unnamed event!" if (!$args{event});
	my $efn = event_to_filename( event => $args{event},
															 category => "current" );

	return "Cannot find event file for node=$args{event}->{node}, event=$args{event}->{event}, element=$args{event}->{element}" if (!$efn or !-f $efn);

	# be polite and robust, fix up any dir perm messes
	setFileProtParents(dirname($efn), $C->{'<nmis_var>'});

	my $hfn = event_to_filename( event => $args{event},
															 category => "history" ); # file to dir is a bit of a hack
	my $historydirname = dirname($hfn) if ($hfn);
	createDir($historydirname) if ($historydirname and !-d $historydirname);
	setFileProtParents($historydirname, $C->{'<nmis_var>'}) if (-d $historydirname);

	# now move the event into the history section if we can,
	# and if we're allowed to
	if (!getbool($C->{"keep_event_history"},"invert") # if not set to 'false'
			and $historydirname and -d $historydirname)
	{
		my $newfn = "$historydirname/".time."-".basename($efn);
			rename($efn, $newfn)
					or return"could not move event file $efn to history: $!";
	}
	else
	{
		unlink($efn)
				or return "could not remove event file $efn: $!";
	}
	return undef;
}

# replaces the event data for one given EXISTING event
# or CREATES a new event with option create_if_missing
#
# args: event (=full record, for finding AND updating)
# create_if_missing (default false)
#
# the node, event name and elements of an event CANNOT be changed,
# because they are part of the naming components!
#
# returns undef if ok, error message otherwise
sub eventUpdate
{
	my (%args) = @_;

	my $C = loadConfTable();

	return "Cannot update unnamed event!" if (!$args{event});
	my $efn = event_to_filename( event => $args{event},
															 category => "current" );
	return "Cannot find event file for node=$args{event}->{node}, event=$args{event}->{event}, element=$args{event}->{element}" if (!$efn or (!-f $efn and !$args{create_if_missing}));

	my $dirname = dirname($efn);
	if (!-d $dirname)
	{
		func::createDir($dirname);
		func::setFileProtParents($dirname, $C->{'<nmis_var>'}); # which includes the parents up to nmis_base
	}

	my $filemode = (-f $efn)? "+<": ">"; # clobber if nonex

	my @problems;
	if (!open(F, $filemode, $efn))
	{
		return "Cannot open event file $efn ($filemode): $!";
	}
	flock(F, LOCK_EX)  or push(@problems, "Cannot lock file $efn: $!");
	&func::enter_critical;
	seek(F, 0, 0);
	truncate(F, 0) or push(@problems, "Cannot truncate file $efn: $!");
	print F encode_json($args{event});
	close(F) or push(@problems, "Cannot close file $efn: $!");
	&func::leave_critical;

	setFileProt($efn);
	if (@problems)
	{
		return join("\n", @problems);
	}
	return undef;
}

# loads one or more service status files and returns the status data
#
# args: service, node, server, only_known (all optional)
# if service or node are given, only matching services are returned.
# server defaults to the local server, and is IGNORED unless only_known is 0.
#
# only_known is 1 by default, which ensures that only locally known, active services
# listed in Services.nmis and attached to active nodes are returned.
#
# if only_known is set to zero, then all services, remote or local,
# active or not are returned.
#
# returns: hash of server -> service -> node -> data; empty if invalid args
sub loadServiceStatus
{
	my (%args) = @_;
	my $C = loadConfTable();			# generally cached anyway

	my $wantnode = $args{node};
	my $wantservice = $args{service};
	my $wantserver = $args{server} || $C->{server_name};
	my $onlyknown = !(getbool($args{only_known}, "invert")); # default is 1


	my $ST = loadServicesTable;
	my $LNT = loadLocalNodeTable;

	my %result;
	# ask the one function that knows where this things live
	my $statusdir = dirname(service_to_filename(service => "dummy",
																							node => "dummy",
																							server => $wantserver));
	return %result if (!$statusdir or !-d $statusdir);
	# figure out which files are relevant, skip dead stuff, then read them
	my @candidates;

	# both node and service present? then check just the one matching service status file
	if ($wantnode and $wantservice)
	{
		my $statusfn = service_to_filename(service => $wantservice,
																			 node => $wantnode,
																			 server => $wantserver);
		# no node or unknown service is ok only if unknowns are allowed
		@candidates = $statusfn if (-f $statusfn
																and (!$onlyknown or
																		 ($LNT->{$wantnode}
																			and $ST->{$wantservice}
																			and $C->{server_name} eq $wantserver)));
	}
	# otherwise read them all...BUT make sure that older files with legacy names
	# do not overwrite the correct new material!
	else
	{
		if (!opendir(D, $statusdir))
		{
			logMsg("ERROR: cannot open dir $statusdir: $!");
			return %result;
		}
		@candidates = map { "$statusdir/$_" } (grep(/\.json$/, readdir(D)));
		closedir(D);
	}

	for my $maybe (@candidates)
	{
		if (!open(F, $maybe))
		{
			logMsg("ERROR: cannot read $maybe: $!");
			next;
		}
		my $raw = join('', <F>);
		close(F);

		my $sdata = eval { decode_json($raw) };
		if ($@ or ref($sdata) ne "HASH")
		{
			logMsg("ERROR: service status file $maybe contains invalid data: $@");
			next;
		}

		my $thisservice = $sdata->{service};
		my $thisnode = $sdata->{node};
		my $thisserver = $sdata->{server} || $C->{server_name};

		# sanity check 1: if we have data for this service already, only accept this
		# if its last_run is strictly newer
		if (ref($result{$thisserver}) eq "HASH"
				&& ref($result{$thisserver}->{$thisservice}) eq "HASH"
				&& ref($result{$thisserver}->{$thisservice}->{$thisnode}) eq "HASH"
				&& $sdata->{last_run} <= $result{$thisserver}->{$thisservice}->{$thisnode}->{last_run})
		{
			dbg("Skipping status file $maybe: would overwrite existing newer data for server $thisserver, service $thisservice, node $thisnode", 1);
			next;
		}

		# sanity check 2: files could be orphaned (ie. deleted node, or deleted service, or no
		# longer listed with the node, or not from this server - all ignored if only_known is false

		if (!$onlyknown
				or ( $thisnode and $LNT->{$thisnode} # known node
						 and $thisservice and $ST->{$thisservice} # known service
						 and $thisserver eq $C->{server_name} # our service
						 and grep($thisservice eq $_, split(/,/, $LNT->{$thisnode}->{services})))) # service still associated with node
		{
			$result{$thisserver}->{$thisservice}->{$thisnode} = $sdata;
		}
	}

	return %result;
}

# takes service, node, and server and translates
# that into the file name for service status saving
# returns: undef if the args were duds, file path otherwise
sub service_to_filename
{
	my (%args) = @_;
	my $C = loadConfTable();			# likely cached

	my ($service, $node, $server) = @args{"service","node","server"};
	return undef if (!$service or !$node or !$server);

	# structure: nmis_var/service_status/<safed service>_<safed node>_<safed server>.json
	# assumption is FLAT dir, so that ONLY this function needs to know the layout
	my $statusdir = $C->{'<nmis_var>'}."/service_status";
	# make sure the event dir exists, ASAP.
	if (! -d $statusdir)
	{
		func::createDir($statusdir);
		func::setFileProt($statusdir, 1);
	}

	my @parts;
	for my $addon ($node,$service,$server)
	{
		my $newcomp = lc($addon);
		$newcomp =~ s![ :/]!_!g; # no slashes possible, no colons and spaces wanted
		push @parts, $newcomp;
	}

	my $result = "$statusdir/".join("_", @parts).".json";
	return $result;
}

# saves and overwrites one service status file
# args: service (= hash of the service data)
# returns: undef if ok, error message otherwise
sub saveServiceStatus
{
	my (%args) = @_;
	my $servicerec = $args{service};

	return "Cannot save service status without status data!"
			if (ref($servicerec) ne "HASH" or !keys %$servicerec);

	# things that *must* be present - undef isn't cutting it
	for my $musthave (qw(status name node service server uuid))
	{
		return "Required property $musthave is missing."
				if (!defined $servicerec->{$musthave});
	}

	my $C = loadConfTable();			# cached
	my $targetfn = service_to_filename(service => $servicerec->{service},
																		 node => $servicerec->{node},
																		 server => $servicerec->{server});
	return "Cannot translate service record into filename!"
			if (!$targetfn);

	writeHashtoFile(file => $targetfn, data => $servicerec, json => "true");
	setFileProt($targetfn);
	return undef;
}

# looks up all events (for one node or all),
# in current or history section
#
# args: node (optional, if not there all are loaded),
# category (optional: default is "current")
# returns hash of: event file name (=full path!) => the event's record
sub loadAllEvents
{
	my (%args) = @_;

	my $C = loadConfTable();			# cached

	my @wantednodes = $args{node}? ($args{node}) : (keys %{loadLocalNodeTable()});
	my $category  = $args{category} || "current";
	my %results = ();

	for my $node (@wantednodes)
	{
		# find the relevant dir via a dummy event and suck them all in
		my $efn = event_to_filename( event => { node => $node,
																						event => "dummy",
																						element => "dummy" },
																 category => $category );
		my $dirname = dirname($efn) if ($efn);
		next if (!$dirname or !-d $dirname);

		opendir(D, $dirname) or logMsg("ERROR could not opendir $dirname: $!");
		my @candidates = readdir(D);
		closedir(D);

		for my $efn (@candidates)
		{
			next if ($efn =~ /^\./ or $efn !~ /\.json$/);

			$efn = "$dirname/$efn";		# for loading and storage
			my $erec = eventLoad(filename => $efn);
			next if (ref($erec) ne "HASH"); # eventLoad already logs errors
			$results{$efn} = $erec;
		}
	}
	return %results;
}

# removes all current events for a node
# this is normally used after editing/deleting nodes to clean the slate and
# make sure there's no lingering phantom events
#
# note: logs if allowed to
# args: node, caller (for logging)
# return nothing
sub cleanEvent
{
	my ($node, $caller) = @_;

	my $C = loadConfTable();

	# find the relevant dir via a dummy event and empty it
	my $efn = event_to_filename( event => { node => $node, event => "dummy", element => "dummy" },
															 category => "current" );
	my $dirname = dirname($efn) if ($efn);
	return if (!$dirname or !-d $dirname);
	func::setFileProtParents($dirname, $C->{'<nmis_var>'});

	$efn = event_to_filename( event => { node => $node, event => "dummy", element => "dummy" },
														category => "history" );
	my $historydirname = dirname($efn) if $efn; # shouldn't fail but BSTS
	func::createDir($historydirname)
			if ($historydirname and !-d $historydirname);
	func::setFileProtParents($historydirname, $C->{'<nmis_var>'}) if (-d $historydirname);

	# get the event configuration which controls logging
	my $events_config = loadTable(dir => 'conf', name => 'Events');

	opendir(D, $dirname) or logMsg("ERROR could not opendir $dirname: $!");
	my @candidates = readdir(D);
	closedir(D);

	for my $moriturus (@candidates)
	{
		next if ($moriturus =~ /^\./ or -d $moriturus or $moriturus !~ /\.json$/);

		# load it so that we can determine whether to log its deletion
		my $erec = eventLoad(filename => "$dirname/$moriturus");
		if (ref($erec) ne "HASH")
		{
			logMsg("ERROR failed to load event file $dirname/$moriturus!");
		}
		my $eventname = $erec->{event} if $erec;

		# log the deletion meta-event iff the original event had logging enabled
		# event logging: true unless overridden by event_config
		if (!$eventname or ref($events_config->{$eventname}) ne "HASH"
				or !getbool($events_config->{$eventname}->{Log}, "invert") )
		{
			# changed to for more consistent handling of events being managed in the GUI.
			my $S = Sys->new;
			$S->init(name => $node);
			checkEvent(sys => $S, node => $node,
									 event => $eventname,
									 element => $erec->{element}||'',
									 details => "closed from $caller: ". $erec->{details}||'closed from $caller'
			);
		}
		# now move the event into the history section if we can
		if ($historydirname and -d $historydirname)
		{
			my $newfn = "$historydirname/".time."-$moriturus";
			rename("$dirname/$moriturus", $newfn)
					or  logMsg("ERROR could not move event file $dirname/$moriturus to history: $!");
		}
		else
		{
			unlink("$dirname/$moriturus")
					or logMsg("ERROR could not remove event file $dirname/$moriturus: $!");
		}
	}
	return;
}

# write a record for a given event to the event log file
# args: node, event, element (may be missing), level, details (may be missing)
# logs errors
# returns: undef if ok, error message otherwise
sub logEvent
{
	my %args = @_;

	my $node = $args{node};
	my $event = $args{event};
	my $element = $args{element};
	my $level = $args{level};
	my $details = $args{details};
	$details =~ s/,//g; # strip any commas

	if (!$node  or !$event or !$level)
	{
		logMsg("ERROR logging event, required argument missing: node=$node, event=$event, level=$level");
		return "required argument missing: node=$node, event=$event, level=$level";
	}

	my $time = time();
	my $C = loadConfTable();

	my @problems;

	# MUST NOT logMsg while holding that lock, as logmsg locks, too!
	sysopen(DATAFILE, "$C->{event_log}", O_WRONLY | O_APPEND | O_CREAT)
			or push(@problems, "Cannot open $C->{event_log}: $!");
	flock(DATAFILE, LOCK_EX)
			or push(@problems,"Cannot lock $C->{event_log}: $!");
	&func::enter_critical;
	# it's possible we shouldn't write if we can't lock it...
	print DATAFILE "$time,$node,$event,$level,$element,$details\n";
	close(DATAFILE) or push(@problems, "Cannot close $C->{event_log}: $!");
	&func::leave_critical;
	setFileProt($C->{event_log}); # set file owner/permission, default: nmis, 0775

	if (@problems)
	{
		my $msg = join("\n", @problems);
		logMsg("ERROR $msg");
		return $msg;
	}
	return undef;
}

# this function (un)acknowledges an existing event
# if configured to it also (event-)logs the activity
#
# args: node, event, element, level, details, ack, user;
# returns: undef if ok, error message otherwise
sub eventAck
{
	my %args = @_;

	my $node = $args{node};
	my $event = $args{event};
	my $element = $args{element};
	my $level = $args{level};
	my $details = $args{details};
	my $ack = $args{ack};
	my $user = $args{user};

	my $C = loadConfTable();
	my $events_config = loadTable(dir => 'conf', name => 'Events');

	# first, find the event
	my $erec = eventLoad(node => $node, event => $event, element => $element);
	if (ref($erec) ne "HASH")
	{
		logMsg("ERROR cannot find event for node=$node, event=$event, element=$element");
		return "cannot find event for node=$node, event=$event, element=$element";
	}

	# event control for logging:  as configured or default true, ie. only off if explicitely configured off.
	my $wantlog = (!$events_config or !$events_config->{$event}
								 or !getbool($events_config->{$event}->{Log}, "invert"))? 1 : 0;

	# events are only acknowledgeable while they are current (ie. not in the process of
	# being deleted)!
	return undef if (!getbool($erec->{current}));

	### if a TRAP type event, then trash when ack. event record will be in event log if required
	if (getbool($ack) and getbool($erec->{ack},"invert") and $event eq "TRAP")
	{
		if (my $error = eventDelete(event => $erec))
		{
			logMsg("ERROR: $error");
		}
		logEvent(node => $node, event => "deleted event: $event",
						 level => "Normal", element => $element) if ($wantlog);
	}
	else	# a 'normal' event
	{
		# nothing to do if requested ack and saved ack the same...
		if (getbool($ack) != getbool($erec->{ack}))
		{
			my $newack = getbool($ack)? 'true' : 'false';

			$erec->{ack} = $newack;
			$erec->{user} = $user;
			if (my $error = eventUpdate(event => $erec))
			{
				logMsg("ERROR: $error");
			}

			logEvent(node => $node, event => $event,
							 level => "Normal", element => $element,
							 details => "acknowledge=$newack ($user)")
					if $wantlog;
		}
	}
	return undef;
}

# this adds one new event OR updates an existing stateless event
# this is a HIGHLEVEL function, doing all kinds of nmis-related stuff!
# to JUST create an event record, use eventUpdate() w/create_if_missing
#
# args: node, event, element (may be missing), level,
# details (may be missing), stateless (optional, default false),
# context (optional, just passed through)
#
# returns: undef if ok, error message otherwise
sub eventAdd
{
	my %args = @_;

	my $node = $args{node};
	my $event = $args{event};
	my $element = $args{element};
	my $level = $args{level};
	my $details = $args{details};
	my $stateless = $args{stateless} || "false";

	my $C = loadConfTable();

	my $efn = event_to_filename( event => { node => $node,
																					event => $event,
																					element => $element },
															 category => "current" );
	return "Cannot create event with missing parameters, node=$node, event=$event, element=$element!"
			if (!$efn);

	# workaround for perl bug(?); the next if's misfire if
	# we do "my $existing = eventLoad() if (-f $efn);"...
	my $existing = undef;
	if (-f $efn)
	{
	    $existing = eventLoad(filename => $efn);
	}

	# is this an already EXISTING stateless event?
	# they will reset after the dampening time, default dampen of 15 minutes.
	if ( ref($existing) eq "HASH" && getbool($existing->{stateless}) )
	{
		my $stateless_event_dampening =  $C->{stateless_event_dampening} || 900;

		# if the stateless time is greater than the dampening time, reset the escalate.
		if ( time() > $existing->{startdate} + $stateless_event_dampening )
		{
			$existing->{current} = 'true';
			$existing->{startdate} = time();
			$existing->{escalate} = -1;
			$existing->{ack} = 'false';
			$existing->{context} ||= $args{context};

			dbg("event stateless, node=$node, event=$event, level=$level, element=$element, details=$details");
			if (my $error = eventUpdate(event => $existing))
			{
				logMsg("ERROR $error");
				return $error;
			}
		}
	}
	# before we log, check the state if there is an event and if it's current
	elsif ( ref($existing) eq "HASH" && getbool($existing->{current}) )
	{
	    dbg("event exists, node=$node, event=$event, level=$level, element=$element, details=$details");
	    logMsg("ERROR cannot add event=$event, node=$node: already exists, is current and not stateless!");
	    return "cannot add event: already exists, is current and not stateless!";
	}
	# doesn't exist or isn't current
	# fixme: existing but not current isn't cleanly handled here
	else
	{
		$existing ||= {};

		$existing->{current} = 'true';
		$existing->{startdate} = time();
		$existing->{node} = $node;
		$existing->{event} = $event;
		$existing->{level} = $level;
		$existing->{element} = $element;
		$existing->{details} = $details;
		$existing->{ack} = 'false';
		$existing->{escalate} = -1;
		$existing->{notify} = "";
		$existing->{stateless} = $stateless;
		$existing->{context} = $args{context};

		if (my $error = eventUpdate(event => $existing, create_if_missing => !(-f $efn)))
		{
			logMsg("ERROR $error");
			return $error;
		}
		dbg("event added, node=$node, event=$event, level=$level, element=$element, details=$details");
		##	logMsg("INFO event added, node=$node, event=$event, level=$level, element=$element, details=$details");
	}

	return undef;
}

# Check event is called after determining that something is back up!
# Check event checks if the given event exists - args are the DOWN event!
# if it exists it deletes it from the event state table/log
#
# and then calls notify with a new Up event including the time of the outage
# args: a LIVE sys object for the node, event(name), upevent (name, optional),
#  element, details (both optional)
#  value, reset (optional, only referenced if event is /proactive/i),
#
# returns: nothing
sub checkEvent
{
	my %args = @_;

	my $S = $args{sys};
	my $node = $S->{node};				# WARNING: this is the lowercased name!
	my $event = $args{event};			# that's the name of the down event
	my $upevent = $args{upevent};	# that's the optional name of the up event to log
	my $element = $args{element};
	my $details = $args{details};

	my $C = loadConfTable();

	# events.nmis controls which events are active/logging/notifying
	# cannot use loadGenericTable as that checks and clashes with db_events_sql
	my $events_config = loadTable(dir => 'conf', name => 'Events');
	my $thisevent_control = $events_config->{$event} || { Log => "true", Notify => "true", Status => "true"};

	# set defaults just in case any are blank.
	$C->{'non_stateful_events'} ||= 'Node Configuration Change, Node Configuration Change Detected, Node Reset, NMIS runtime exceeded, Interface ifAdminStatus Changed';
	$C->{'threshold_falling_reset_dampening'} ||= 1.1;
	$C->{'threshold_rising_reset_dampening'} ||= 0.9;

	# check if the (down) event exists and load its details
	my $event_exists = eventExist($node, $event, $element);
	my $erec = eventLoad(filename => $event_exists) if $event_exists;

	if ($event_exists
			and getbool($erec->{current}))
	{
		# a down event exists, so log an UP and delete the original event

		# cmpute the event period for logging
		my $outage = convertSecsHours(time() - $erec->{startdate});

		if ($upevent)						# caller has told us a preferred up event name
		{
			$event = $upevent;
		}
		elsif ( $event eq "Node Down" )
		{
			$event = "Node Up";
		}
		elsif ( $event eq "Interface Down" )
		{
			$event = "Interface Up";
		}
		elsif ( $event eq "RPS Fail" )
		{
			$event = "RPS Up";
		}
		elsif ( $event =~ /Proactive/ )
		{
			my ($value,$reset) = @args{"value","reset"};
			if (defined $value and defined $reset)
			{
				# but only if we have cleared the threshold by 10%
				# for thresholds where high = good (default 1.1)
				# for thresholds where low = good (default 0.9)
				my $cutoff = $reset * ($value >= $reset?
															 $C->{'threshold_falling_reset_dampening'}
															 : $C->{'threshold_rising_reset_dampening'});

				if ( $value >= $reset && $value <= $cutoff )
				{
					info("Proactive Event value $value too low for dampening limit $cutoff. Not closing.");
					return;
				}
				elsif ($value < $reset && $value >= $cutoff)
				{
					info("Proactive Event value $value too high for dampening limit $cutoff. Not closing.");
					return;
				}
			}
			$event = "$event Closed";
		}
		elsif ( $event =~ /^Alert/ )
		{
			# A custom alert is being cleared.
			$event = "$event Closed";
		}
		elsif ( $event =~ /down/i )
		{
			$event =~ s/down/Up/i;
		}
		elsif ($event =~ /\Wopen($|\W)/i)
		{
			$event =~ s/(\W)open($|\W)/$1Closed$2/i;
		}

		# event was renamed/inverted/massaged, need to get the right control record
		# this is likely not needed
		$thisevent_control = $events_config->{$event} || { Log => "true", Notify => "true", Status => "true"};

		$details .= ($details? " " : "") . "Time=$outage";

		my ($level,$log,$syslog) = getLevelLogEvent(sys=>$S, event=>$event, level=>'Normal');

		# the REAL node name is required, not lowercased!
		my ($otg,$outageinfo) = outageCheck(node => $S->{name}, time=>time());
		if ($otg eq 'current') {
			$details .= " outage_current=true change=$outageinfo->{change_id}";
		}

		# now we save the new up event, and move the old down event into history
		my $newevent = { %$erec };
		$newevent->{current} = 'false'; # next processing by escalation routine
		$newevent->{event} = $event;
		$newevent->{details} = $details;
		$newevent->{level} = $level;
		# so the event has the time it was logged cached.
		$newevent->{enddate} = time();

		# make the new one FIRST
		if (my $error = eventUpdate(event => $newevent, create_if_missing => 1))
		{
			logMsg("ERROR $error");
		}
		# then delete/move the old one, but only if all is well
		else
		{
			if ($error = eventDelete(event => $erec))
			{
				logMsg("ERROR $error");
			}
		}

		dbg("event node=$erec->{node}, event=$erec->{event}, element=$erec->{element} marked for UP notify and delete");
		if (getbool($log) and getbool($thisevent_control->{Log}))
		{
			logEvent( node=>$S->{name},
								event=>$event,
								level=>$level,
								element=>$element,
								details=>$details);
		}

		# Syslog must be explicitly enabled in the config and will escalation is not being used.
		if (getbool($C->{syslog_events}) and getbool($syslog)
				and getbool($thisevent_control->{Log})
				and !getbool($C->{syslog_use_escalation}))
		{
			sendSyslog(
				server_string => $C->{syslog_server},
				facility => $C->{syslog_facility},
				nmis_host => $C->{server_name},
				time => time(),
				node => $S->{name},
				event => $event,
				level => $level,
				element => $element,
				details => $details
			);
		}
	}
}

# notify creates new events
# OR updates level changes for existing threshold/alert ones
# note that notify ignores any outage configuration.
#
# args: LIVE sys for this node, event(=name), element (optional),
# details, level (all optional), context (optional, deep structure)
# returns: nothing
sub notify
{
	my %args = @_;
	my $S = $args{sys};
	my $NI = $S->ndinfo;
	my $M = $S->mdl;

	my $event = $args{event};
	my $element = $args{element};
	my $details = $args{details};
	my $level = $args{level};

	my $node = $S->{name};
	my $log;
	my $syslog;

	my $C = loadConfTable();

	dbg("Start of Notify");

	# events.nmis controls which events are active/logging/notifying
	# cannot use loadGenericTable as that checks and clashes with db_events_sql
	my $events_config = loadTable(dir => 'conf', name => 'Events');
	my $thisevent_control = $events_config->{$event} || { Log => "true", Notify => "true", Status => "true"};


	my $event_exists = eventExist($S->{name},$event,$element);
	my $erec = eventLoad(filename => $event_exists) if $event_exists;


	if ( $event_exists and getbool($erec->{current}))
	{
		# event exists, maybe a level change of proactive threshold?
		if ($event =~ /Proactive|Alert\:/ )
		{
			if ($erec->{level} ne $level)
			{
				# change of level; must update the event record
				# note: 2014-08-27 keiths, update the details as well when changing the level
				$erec->{level} = $level;
				$erec->{details} = $details;
				$erec->{context} ||= $args{context};
				if (my $error = eventUpdate(event => $erec))
				{
					logMsg("ERROR $error");
				}

				(undef, $log, $syslog) = getLevelLogEvent(sys=>$S, event=>$event, level=>$level);
				$details .= " Updated";

				# send a json event if this matches an escalation policy.........
				# if Event Exits and "notify" : "json:server", includes "json:"
				# then log a json update event.......
				if ( $erec->{notify} =~ /json:/ ) {
					# clone the event, update the details and log it.
					my $logEvent = $erec;
					$logEvent->{details} .= " Updated";
					logJsonEvent(event => $logEvent, dir => $C->{'json_logs'});
				}
			}
		}
		else # not an proactive/alert event - no changes are supported
		{
			dbg("Event node=$node event=$event element=$element already exists");
		}
	}
	else # event doesn't exist OR is set to non-current
	{
		# get level(if not defined) and log status from Model
		($level,$log,$syslog) = getLevelLogEvent(sys=>$S, event=>$event, level=>$level);

		my $is_stateless = ($C->{non_stateful_events} !~ /$event/
												or getbool($thisevent_control->{Stateful}))? "false": "true";

		my ($otg,$outageinfo) = outageCheck(node=>$node,time=>time());
		if ($otg eq 'current') {
			$details .= ($details? " ":""). "outage_current=true change=$outageinfo->{change_id}";
		}

		# Create and store this new event; record whether stateful or not
		# a stateless event should escalate to a level and then be automatically deleted.
		if (my $error = eventAdd( node=>$node, event=>$event, level=>$level,
															element=>$element, details=>$details,
															stateless => $is_stateless, context => $args{context}))
		{
			logMsg("ERROR: $error");
		}

		if (getbool($C->{log_node_configuration_events})
				and $C->{node_configuration_events} =~ /$event/
				and getbool($thisevent_control->{Log}))
		{
			logConfigEvent(dir => $C->{config_logs}, node=>$node, event=>$event, level=>$level,
										 element=>$element, details=>$details, host => $NI->{system}{host},
										 nmis_server => $C->{nmis_host} );
		}
	}

	# log events if allowed
	if ( getbool($log) and getbool($thisevent_control->{Log}))
	{
		logEvent(node=>$node, event=>$event, level=>$level, element=>$element, details=>$details);
	}

	# Syslog must be explicitly enabled in the config and
	# is used only if escalation isn't
	if (getbool($C->{syslog_events})
			and getbool($syslog)
			and getbool($thisevent_control->{Log})
			and !getbool($C->{syslog_use_escalation}))
	{
		sendSyslog(
			server_string => $C->{syslog_server},
			facility => $C->{syslog_facility},
			nmis_host => $C->{server_name},
			time => time(),
			node => $node,
			event => $event,
			level => $level,
			element => $element,
			details => $details
				);
	}

	dbg("Finished");
}

# translates a full event structure into a filename
# args: event (= hashref), category (optional, current or history;
# otherwise taken from event - event with current=false go into history)
#
# returns: file name or undef if inputs make no sense
sub event_to_filename
{
	my (%args) = @_;
	my $C = loadConfTable();			# likely cached

	my $erec = $args{event};
	return undef if (!$erec or ref($erec) ne "HASH" or !$erec->{node}
									 or !$erec->{event}); # element is optional

	# note: just a few spots need to know anything about this structure (or its location):
	# here, in the upgrade_events_structure function (assumes under var),
	# eventDelete, eventUpdate and cleanEvent functions (assume under nmis_var)
	# and in nmis_file_cleanup.sh.
	#
	# structure: nmis_var/events/lcNODENAME/{current,history}/EVENTNAME.json
	my $eventbasedir = $C->{'<nmis_var>'}."/events";
	# make sure the event dir exists, ASAP.
	if (! -d $eventbasedir)
	{
		func::createDir($eventbasedir);
		func::setFileProt($eventbasedir);
	}

	# overridden, or not current then history, or
	my $category = defined($args{category}) && $args{category} =~ /^(current|history)$/?
			$args{category} : getbool($erec->{current})? "current" : "history";

	my $nodecomp = lc($erec->{node});
	$nodecomp =~ s![ :/]!_!g; # no slashes possible, no colons and spaces just for backwards compat

	my $eventcomp = lc($erec->{event}."-".($erec->{element}? $erec->{element} : ''));
	$eventcomp =~ s![ :/]!_!g;			#  backwards compat

	my $result = "$eventbasedir/$nodecomp/$category/$eventcomp.json";
	return $result;
}

# this reads an old-style nmis-events file if present,
# and splits the events out into the desired new dir structure
# when done it renames the nmis-events file.
# returns undef if everything is done, error message otherwise
sub upgrade_events_structure
{
	my $C = loadConfTable();			# likely cached

	# we're clearly done if no nmis-events.{nmis,json} exists
	my $oldeventfile = func::getFileName(file => $C->{'<nmis_var>'}."/nmis-event");
	return undef if (!-f $oldeventfile);

	# load and lock the existing events file
	my ($old, $fh) = loadTable( dir=>'var', name=>'nmis-event', lock=>'true');

	for my $eventkey (keys %$old)
	{
		my $eventrec = $old->{$eventkey};
		next if (!$eventrec or !%$eventrec);				# deal with incorrectly vivified dud blank events

		my $newfn = event_to_filename(event => $eventrec);
		if (!$newfn)
		{
			close $fh;
			return "Error: no file name for eventkey $eventkey!";
		}

		my $dirname = dirname($newfn);
		if (!-d $dirname)
		{
			func::createDir($dirname);
			func::setFileProt($dirname);
		}

		if (!open(F, ">$newfn"))
		{
			my $problem = $!;
			close $fh;
			return "cannot write to $newfn: $problem";
		}
		print F encode_json($eventrec);
		close(F);
		# now be nice: update the file modification (and access) timestamps to match the startdate property,
		# the file creation time we CANNOT change...
		utime($eventrec->{startdate}, $eventrec->{startdate}, $newfn); #ignore problems, not important
	}

	# and now that we're mostly done, ensure the permissiones make sense
	# fixme: this assumes that events is under var; must align with event_to_filename!
	func::setFileProtDirectory($C->{'<nmis_var>'}, 1);

	# finally, renmae the event file away
	if (!rename($oldeventfile, "$oldeventfile.disabled"))
	{
		my $problem = $!;
		close $fh;
		return "cannot rename $oldeventfile: $problem";
	}
	close $fh;
	logMsg("INFO NMIS has successfully converted the nmis-event data structure, and the old event file was renamed to \"$oldeventfile.disabled\".");

	return undef;
}


# this reads an old-style nodeconf table file if present,
# and splits stuff into per-node json files under conf/overrides/
# when done it renames the nmis-events file.
# returns undef if everything is done, error message otherwise
sub upgrade_nodeconf_structure
{
	my $C = loadConfTable();			# likely cached
	my $LNT = loadLocalNodeTable(sanitise => 1); # this removes garbage data

	# anything left to do?
	my $oldncf = func::getFileName(file => $C->{'<nmis_conf>'}."/nodeConf");
	return undef if (!-f $oldncf);

	# load and lock the old file
	my ($old, $fh) = loadTable( dir=>'conf', name=>'nodeConf', lock=>'true');

	for my $nodekey (keys %$old)
	{
		# skip data for nonexistent nodes
		next if (!$LNT->{$nodekey});

		# nodeconf data must include the original nodename, as the filename won't necessarily.
		$old->{$nodekey}->{name} = $nodekey;

		if (my $errormsg = update_nodeconf(node => $nodekey,
																			 data => $old->{$nodekey}))
		{
			close $fh;
			return "Error: failed to update nodeconf for $nodekey: $errormsg";
		}
	}
	# move the old nodeconf file away
	if (!rename($oldncf, "$oldncf.disabled"))
	{
		my $problem = $!;
		close $fh;
		return "cannot rename $oldncf: $problem";
	}
	close $fh;
	logMsg("INFO NMIS has successfully converted the nodeConf data structure, and the old nodeConf file was renamed to \"$oldncf.disabled\".");

	return undef;
}

# saves a given nodeconf data structure in the per-node nodeconf file
# args: node, data (required)
# data can be undef; in this case the nodeconf for this node is removed.
#
# returns: undef if ok, error message otherwise
sub update_nodeconf
{
	my (%args) = @_;
	my $nodename = $args{node};
	my $data = $args{data};

	my $C = loadConfTable();			# likely cached

	return "Cannot save nodeconf without nodename argument!"
			if (!$nodename);					# note: we don't check (yet) if the node is known

	return "Cannot save nodeconf for $nodename, data is missing!"
			if (!exists($args{data}));				# present but explicitely undef is ok

	my $safenodename = lc($nodename);
	$safenodename =~ s/[^a-z0-9_-]/_/g;
	my $ncdirname = $C->{'<nmis_conf>'}."/nodeconf";
	if (!-d $ncdirname)
	{
		func::createDir($ncdirname);
		my $errmsg = func::setFileProtDiag(file => $ncdirname);
		return $errmsg if ($errmsg);
	}

	my $ncfn = "$ncdirname/$safenodename.json";

	# the deletion case
	if (!defined($data))
	{
		return "Could not remove nodeconf for $nodename: $!"
				if (!unlink($ncfn));
	}
	# we overwrite whatever may have been there
	else
	{
		# ensure that the nodeconf data includes the nodename, as the filename might not!
		$data->{name} ||= $nodename;

		# unfortunately this doesn't return errors
		writeHashtoFile(file => $ncfn, data => $data, json => 1);
	}
	return undef;
}

# small helper that checks if a nodeconf record
# exists for the given node.
#
# args: node (required)
# returns: filename if it exists, 0 if not, undef if the args are dud
sub has_nodeconf
{
	my (%args) = @_;
	my $nodename = $args{node};
	return undef if (!$nodename);

	$nodename = lc($nodename);
	$nodename =~ s/[^a-z0-9_-]/_/g;

	my $C = loadConfTable();			# likely cached
	my $ncfn = $C->{'<nmis_conf>'}."/nodeconf/$nodename.json";
	return (-f $ncfn? $ncfn : 0);
}

# returns the nodeconf record for one or all nodes
# args: node (optional)
# returns: (undef, hashref) or (errmsg, undef)
# if asked for a single node, then hashref is JUST the node's settings
# if asked for all nodes, then hashref is nodename => per-node-settings
sub get_nodeconf
{
	my (%args) = @_;
	my $nodename = $args{node};

	if (exists($args{node}))
	{
		return "Cannot get nodeconf for unnamed node!" if (!$nodename);

		my $ncfn = has_nodeconf(node => $nodename);
		return "No nodeconf exists for node $nodename!" if (!$ncfn);

		my $data = readFiletoHash(file => $ncfn, json => 1);
		return "Failed to read nodeconf for $nodename!"
				if (ref($data) ne "HASH");

		return (undef, $data );
	}
	else
	{
		# walk the dir
		my $C = loadConfTable();			# likely cached
		my $ncdir = $C->{'<nmis_conf>'}."/nodeconf";
		opendir(D, $ncdir)
				or return "Cannot open nodeconf dir: $!";
		my @cands = grep(/^[a-z0-9_-]+\.json$/, readdir(D));
		closedir(D);

		my %allofthem;

		for my $maybe (@cands)
		{
			my $data = readFiletoHash(file => "$ncdir/$maybe", json => 1);
			if (ref($data) ne "HASH" or !keys %$data or !$data->{name})
			{
				logMsg("ERROR nodeconf $ncdir/$maybe had invalid data! Skipping.");
				next;
			}

			# structure is real_nodename => data for this node
			$allofthem{$data->{name}} = $data;
		}
		return (undef, \%allofthem);
	}
}


# this is now a backwards-compatibilty wrapper around get_nodeconf()
sub loadNodeConfTable
{
	my ($error, $data) = get_nodeconf;
	if ($error)
	{
		logMsg("ERROR get_nodeconf failed: $error");
		return {};
	}
	return $data;
}

# this method returns 1 or 0 if one of collect, collect_snmp or collect_wmi is true
# this depends on the node table cache system to run super fast.
#
# args: node => node name
sub isNodeCollectable
{
	my (%args) = @_;
	my $nodename = $args{node};
	my $NT = loadNodeTable();

	my $nodeCollectable = getbool($NT->{$nodename}{collect}) or getbool($NT->{$nodename}{collect_snmp}) or getbool($NT->{$nodename}{collect_wmi}) ? 1 : 0;

	return $nodeCollectable;
}

# this method renames a node, and all its files, too
#
# args: old, new,
# (optional) debug, (optional) info, (optional) originator
# originator is used for cleanEvent
# returns: (0,undef) if ok, (1, error message) if op failed
#
# note: prints progress info to stderr if debug or info are enabled!
sub rename_node
{
	my (%args) = @_;

	my ($old, $new) = @args{"old","new"};
	my $wantdiag = func::setDebug($args{debug})
			|| func::setDebug($args{info}); # don't care about the actual values

	return (1, "Cannot rename node without separate old and new names!")
			if (!$old or !$new or $old eq $new);

	my $C = loadConfTable();

	my $nodeinfo = loadLocalNodeTable();
	my $oldnoderec = $nodeinfo->{$old};
	return (1, "Old node $old does not exist!") if (!$oldnoderec);

	my $nodenamerule = $C->{node_name_rule} || qr/^[a-zA-Z0-9_. -]+$/;
	return(1, "Invalid node name \"$new\"")	if ($new !~ $nodenamerule);

	my $newnoderec = $nodeinfo->{$new};
	return(1, "New node $new already exists, NOT overwriting!")
			if ($newnoderec);

	# rename must not interfere with collect or update,
	# so let's check those lockfiles - then acquire an update lock
	# fixme: existsPollLock + createPollLock is insufficiently atomic to be perfectly reliable)
	for my $nogoodlock (qw(collect update))
	{
		return (1, "Cannot rename node while an $nogoodlock operation is running!")
				if (existsPollLock(type => $nogoodlock, conf => $C->{conf}, node => $old));
	}
	my $lockHandle = createPollLock(type => "update",
																	conf => $C->{conf},
																	node => $old);
	return (1, "Failed to create lock for rename operation") if (!$lockHandle);

	$newnoderec = { %$oldnoderec  };
	$newnoderec->{name} = $new;
	$nodeinfo->{$new} = $newnoderec;

	# save the nodes file away, so that we can restore it if needed
	my $nodesfile = $C->{'<nmis_conf>'}."/Nodes.nmis";
	my $backupfile = $C->{'<nmis_conf>'}."/Nodes.nmis.pre-rename";
	unlink($backupfile); 					# make room, make room; should not be present
	File::Copy::mv($nodesfile, $backupfile); # that should preserve the permissions

	# now write out the new nodes file, so that the new node becomes
	# workable (with sys etc)
	# fixme lowprio: if db_nodes_sql is enabled we need to use a
	#different write function
	print STDERR "Saving new name in Nodes table\n" if ($wantdiag);
	writeTable(dir => 'conf', name => "Nodes", data => $nodeinfo);

	# then hardlink the var files - do not delete anything yet!
	my @todelete;
	my $vardir = $C->{'<nmis_var>'};
	if (!opendir(D, $vardir))
	{
		File::Copy::mv($backupfile,$nodesfile);
		releasePollLock(handle => $lockHandle, type => "update", conf => $C->{conf}, node => $old);
		return(1, "cannot read dir $vardir: $!");
	}
	for my $fn (readdir(D))
	{
		if ($fn =~ /^$old-(node|view)\.(\S+)$/i)
		{
			my ($component,$ext) = ($1,$2);
			my $newfn = lc("$new-$component.$ext");
			push @todelete, "$vardir/$fn";

			print STDERR "Renaming/linking var/$fn to $newfn\n" if ($wantdiag);
			unlink("$vardir/$newfn") if (-e "$vardir/$newfn"); # would conflict, we want to overwrite
			if (!link("$vardir/$fn", "$vardir/$newfn"))
			{
				File::Copy::mv($backupfile,$nodesfile);
				releasePollLock(handle => $lockHandle, type => "update", conf => $C->{conf}, node => $old);
				return(1,"cannot hardlink $fn to $newfn: $!");
			}
		}
	}
	closedir(D);

	print STDERR "Priming Sys objects for finding RRDs\n" if ($wantdiag);
	# now prime sys objs for both old and new nodes, so that we can find and translate rrd names
	my $oldsys = Sys->new; $oldsys->init(name => $old, snmp => "false");
	my $newsys = Sys->new; $newsys->init(name => $new, snmp => "false");

	my $oldinfo = $oldsys->ndinfo;
	my %seen;									 # state cache for renamerrd

	# find all rrds belonging to the old node
	for my $section (keys %{$oldinfo->{graphtype}})
	{
		if (ref($oldinfo->{graphtype}->{$section}) eq "HASH")
		{
			my $index = $section;
			for my $subsection (keys %{$oldinfo->{graphtype}->{$section}})
			{
				if ($subsection =~ /^cbqos-(in|out)$/)
				{
					my $dir = $1;
					# need to find the qos classes and hand them to getdbname as item
					for my $classid (keys %{$oldinfo->{cbqos}->{$index}->{$dir}->{ClassMap}})
					{
						my $item = $oldinfo->{cbqos}->{$index}->{$dir}->{ClassMap}->{$classid}->{Name};
						push @todelete, renameRRD(old => $oldsys, new => $newsys, graphtype => $subsection,
																			index => $index, item => $item, debug => $wantdiag,
																			seen => \%seen);
					}
				}
				else
				{
					push @todelete, renameRRD(old => $oldsys, new => $newsys, graphtype => $subsection,
																		index => $index, debug => $wantdiag, seen => \%seen);
				}
			}
		}
		else
		{
			push @todelete, renameRRD(old => $oldsys, new => $newsys, graphtype => $section,
																debug => $wantdiag, seen => \%seen);
		}
	}

	# then deal with the no longer wanted data: remove the old links
	for my $fn (@todelete)
	{
		next if (!defined $fn);
		my $relfn = File::Spec->abs2rel($fn, $C->{'<nmis_base>'});
		print STDERR "Deleting file $relfn, no longer required\n" if ($wantdiag);
		unlink($fn);
	}

	# now, finally reread the nodes table and remove the old node
	print STDERR "Deleting old node $old from Nodes table\n" if ($wantdiag);
	my $newnodeinfo = loadLocalNodeTable();
	delete $newnodeinfo->{$old};
	# fixme lowprio: if db_nodes_sql is enabled we need to use a
	# different write function
	writeTable(dir => 'conf', name => "Nodes", data => $newnodeinfo);

	# now clear all events for old node
	print STDERR "Removing events for old node\n" if ($wantdiag);
	cleanEvent($old,$args{originator});

	print STDERR "Successfully renamed node $old to $new\n" if ($wantdiag);
	releasePollLock(handle => $lockHandle, type => "update", conf => $C->{conf}, node => $old);
	unlink($backupfile);

	return (0,undef);
}

# internal helper function for rename_node, LINKS one given rrd file to new name
# caller must take care of removing the old rrd file later.
#
# args: old and new (both sys objects), graphtype, seen (hash REF for state caching),
# index (optional), item (optional), info, debug (both optional),
# returns: old (now removable) file name, or undef if nothing done
#
# higher-level functionality/logic, so NOT a candidate for rrdfunc.pm.
#
# note: prints diags on stderr if info or debug are set!
sub renameRRD
{
	my (%args) = @_;

	my $C = loadConfTable();

	my $oldfilename = $args{old}->getDBName(graphtype => $args{graphtype},
																			 index => $args{index},
																			 item => $args{item});
	# don't try to rename a file more than once...
	return undef if $args{seen}->{$oldfilename};
	$args{seen}->{$oldfilename}=1;

	my $wantdiag = func::setDebug($args{debug})
			|| func::setDebug($args{info}); # don't care about the actual values

	my $newfilename = $args{new}->getDBName(graphtype => $args{graphtype},
																			 index => $args{index},
																			 item => $args{item});
	return undef if ($newfilename eq $oldfilename);

	if (!$newfilename or !$oldfilename)
	{
		print STDERR "Warning: no RRD file name found for graphtype $args{graphtype} index $args{index} item $args{item}\n"
				if ($wantdiag);
		return undef;
	}

	my $oldrelname = File::Spec->abs2rel( $oldfilename, $C->{'<nmis_base>'} );
	my $newrelname = File::Spec->abs2rel( $newfilename, $C->{'<nmis_base>'} );

	if (!-f $oldfilename)
	{
		print STDERR "Warning: RRD file $oldrelname does not exist, cannot rename!\n" if ($wantdiag);
		return undef;
	}

	# ensure the target dir hierarchy exists
	my $dirname = dirname($newfilename);
	if (!-d $dirname)
	{
		print STDERR "Creating directory $dirname for RRD files\n" if ($wantdiag);
		my $curdir;
		for my $component (File::Spec->splitdir($dirname))
		{
			next if !$component;
			$curdir.="/$component";
			if (!-d $curdir)
			{
				if (!mkdir $curdir,0755)
				{
					print STDERR "cannot create directory $curdir: $!\n"  if ($wantdiag);
					return undef;
				}
				setFileProt($curdir);
			}
		}
	}

	print STDERR "Renaming/linking RRD file $oldrelname to $newrelname\n" if ($wantdiag);
	if (!link($oldfilename,$newfilename))
	{
		print STDERR "cannot link $oldrelname to $newrelname: $!\n"  if ($wantdiag);
		return undef;
	}

	return $oldfilename;
}

1;
