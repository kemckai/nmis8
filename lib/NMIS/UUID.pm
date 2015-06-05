#
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
package NMIS::UUID;
our $VERSION  = "1.1.1";

use strict;
use Fcntl qw(:DEFAULT :flock);
use NMIS;
use func;
use UUID::Tiny qw(:std);

use vars qw(@ISA @EXPORT @EXPORT_OK %EXPORT_TAGS );

use Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(auditNodeUUID createNodeUUID getUUID);


# check which nodes do not have UUID's.
sub auditNodeUUID {
	#load nodes
	#foreach node
	# Does it have a UUID?
	# Print exception
	#done
	my $C = loadConfTable();
	my $success = 1;
	my $LNT = loadLocalNodeTable();
	my $UUID_INDEX;
	foreach my $node (sort keys %{$LNT}) {
		if (!keys %{$LNT->{$node}})
		{
			print "ERROR: $node is completely blank!\n";
		}
	  elsif ( $LNT->{$node}{uuid} eq "" ) {	  	
	    print "ERROR: $node does not have a UUID\n";
		}
		else {
			print "Node: $node, UUID: $LNT->{$node}{uuid}\n" if $C->{debug};
			if ($UUID_INDEX->{$LNT->{$node}{uuid}} ne "" ) {
				print "ERROR: the improbable has happened, a UUID conflict has been found for $LNT->{$node}{uuid}, between $node and $UUID_INDEX->{$LNT->{$node}{uuid}}\n";
			}
			else {
				$UUID_INDEX->{$LNT->{$node}{uuid}} = $node;
				$UUID_INDEX->{$node} = $LNT->{$node}{uuid};
			}
		}
	}
	writeHashtoFile(file => "$C->{'<nmis_conf>'}/UUID", data => $UUID_INDEX);
	return $success;
}

# translate between data::uuid and uuid::tiny namespace constants
# namespace_<X> (url,dns,oid,x500) in data::uuid correspond to UUID_NS_<X> in uuid::tiny
my %known_namespaces = map { my $varname = "UUID_NS_$_"; 
														 ("NameSpace_$_" => UUID::Tiny->$varname, 
															$varname => UUID::Tiny->$varname) } (qw(DNS OID URL X500));


sub createNodeUUID {
	#load nodes
	#foreach node
	# Does it have a UUID?
	# create one, assign it
	#done
	#save nodes

	my $C = loadConfTable();
	my $success = 1;
	my $LNT = loadLocalNodeTable();

	my $UUID_INDEX;
	foreach my $node (sort keys %{$LNT}) {
		next if (!keys %{$LNT->{$node}});  # auto-vivified blank zombie node
	  if ( $LNT->{$node}{uuid} eq "" ) {
			print "CREATE UUID for $node\n" if $C->{debug};
			
	    #'uuid_namespace_type' => 'NameSpace_URL' OR "UUID_NS_DNS"
	    #'uuid_namespace_name' => 'www.domain.com' AND we need to add the nodename to make it unique,
			# because if namespaced, then name is the ONLY thing controlling the resulting uuid!
	    my $uuid;
			
	    if ( $known_namespaces{$C->{'uuid_namespace_type'}}
					 and defined($C->{'uuid_namespace_name'})
					 and $C->{'uuid_namespace_name'} ne ""
					 and $C->{'uuid_namespace_name'} ne "www.domain.com" ) 
			{
				$uuid = create_uuid_as_string(UUID_V5, $known_namespaces{$C->{uuid_namespace_type}}, 
																			$C->{uuid_namespace_name}.$node);
			}
			else {
		    $uuid = create_uuid_as_string(UUID_V1); # fixme UUID_RANDOM would be better, but the old module used V1
			}
			$LNT->{$node}{uuid} = $uuid;
		}
		print "Node: $node, UUID: $LNT->{$node}{uuid}\n" if $C->{debug};
		if ($UUID_INDEX->{$LNT->{$node}{uuid}} ne "" ) {
			print "ERROR: the improbable has happened, a UUID conflict has been found for $LNT->{$node}{uuid}, between $node and $UUID_INDEX->{$LNT->{$node}{uuid}}\n";
		}
		else {
			$UUID_INDEX->{$LNT->{$node}{uuid}} = $node;
		}
	}
	my $ext = getExtension(dir=>'conf');
	backupFile(file => "$C->{'<nmis_conf>'}/Nodes.$ext", backup => "$C->{'<nmis_conf>'}/Nodes.$ext.bak");
	writeHashtoFile(file => "$C->{'<nmis_conf>'}/Nodes", data => $LNT);
	writeHashtoFile(file => "$C->{'<nmis_conf>'}/UUID", data => $UUID_INDEX);
	return $success;
}

#  this function doesn't take any args, or know a nodename to pass in (is run pre node-creation),
# so we add a random component to make the namespaced uuid work
sub getUUID 
{
  my $uuid;
	my $C = loadConfTable();
	
	if ($known_namespaces{$C->{"uuid_namespace_type"}}
			and defined($C->{'uuid_namespace_name'})
			and $C->{'uuid_namespace_name'} ne "" 
			and $C->{'uuid_namespace_name'} ne "www.domain.com" )
	{
		# namespace prefix plus random 
    $uuid = create_uuid_as_string(UUID_V5, $known_namespaces{$C->{'uuid_namespace_type'}}, 
																	$C->{'uuid_namespace_name'}.create_uuid(UUID_RANDOM));
	}
	else {
    $uuid = create_uuid_as_string(UUID_V1); # fixme: UUID_RANDOM would be better, but the old module used V1
	}
	return $uuid;
}

1;
