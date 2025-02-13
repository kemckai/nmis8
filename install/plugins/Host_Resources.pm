#
#  Copyright Opmantek Limited (www.opmantek.com)
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
#

package Host_Resources;
our $VERSION = "1.0.0";

use strict;
#use warnings;
use func;	# for the conf table extras
use NMIS;
use rrdfunc;
use Data::Dumper;

sub collect_plugin
{
	my (%args) = @_;
	my ($node,$S,$C) = @args{qw(node sys config)};

	my $NI = $S->ndinfo;
	# $NI refers to *-node.json file. eg s2laba1mux1g1-node.json

	my $changesweremade = 0;

	if (ref($NI->{Host_Storage}) eq "HASH") {

		info("Working on $node Host Memory Calculations");

		# for saving all the types of memory we want to use
		my $Host_Memory;

		# look through each of the different types of memory for cache and buffer
		foreach my $index (sort keys %{$NI->{Host_Storage}}) {
			$changesweremade = 1;
			my $entry = $NI->{Host_Storage}{$index};

			my $type = undef;
			my $typeName = undef;

			# is this the physical memory?
			if ( defined $entry->{hrStorageDescr} ) {

				if ( $entry->{hrStorageDescr} =~ /(Physical memory|RAM)/ ) {
					$typeName = "Memory";
					$type = "physical";
				}
				elsif ( $entry->{hrStorageDescr} =~ /(Cached memory|RAM \(Cache\))/ ) {
					$typeName = "Memory";
					$type = "cached";
				}
				elsif ( $entry->{hrStorageDescr} =~ /(Memory buffers|RAM \(Buffers\))/ ) {
					$typeName = "Memory";
					$type = "buffers";
				}
				elsif ( $entry->{hrStorageDescr} =~ /Virtual memory/ ) {
					$typeName = "Memory";
					$type = "virtual";
				}
				elsif ( $entry->{hrStorageDescr} =~ /Swap space/ ) {
					$typeName = "Memory";
					$type = "swap";
				}
				elsif ( $entry->{hrStorageType} =~ /FixedDisk/ ) {
					$typeName = "Fixed Disk";
					$type = "disk";
				}
				elsif ( $entry->{hrStorageType} =~ /NetworkDisk/ ) {
					$typeName = "Network Disk";
					$type = "disk";
				}
				elsif ( $entry->{hrStorageType} =~ /RemovableDisk/ ) {
					$typeName = "Removable Disk";
					$type = "disk";
				}
				elsif ( $entry->{hrStorageType} =~ /Disk/ ) {
					$typeName = "Other Disk";
					$type = "disk";
				}
				elsif ( $entry->{hrStorageType} =~ /FlashMemory/ ) {
					$typeName = "Flash Memory";
					$type = "disk";
				}
				else {
					$typeName = $entry->{hrStorageType};
					$type = "other";
				}
			}
			else {
				$typeName = "Unknown";
				$type = "other";
			}

			if ( $typeName eq "Memory" ) {
				info("Host Memory Type = $entry->{hrStorageDescr} interesting as $type");
			}
			else {
				info("Host Storage Type = $entry->{hrStorageDescr} less interesting") if defined $entry->{hrStorageDescr};
			}

			# do we have a type of memory to process?
			if ( defined $type ) {
				$Host_Memory->{$type ."_total"} = $entry->{hrStorageSize};
				$Host_Memory->{$type ."_used"} = $entry->{hrStorageUsed};
				$Host_Memory->{$type ."_units"} = $entry->{hrStorageAllocationUnits};
			}

			if ( defined $entry->{hrStorageUnits} and defined $entry->{hrStorageSize} and defined $entry->{hrStorageUsed} ) {
				# must guard against 'noSuchInstance', which surivies first check b/c non-empty
				my $sizeisnumber = ( $entry->{hrStorageSize}
														 # int or float
														 && $entry->{hrStorageSize} =~ /^([+-]?)(?=\d|\.\d)\d*(\.\d*)?([Ee]([+-]?\d+))?$/ );

				$entry->{hrStorageUtil} = sprintf("%.1f", $entry->{hrStorageUsed} / $entry->{hrStorageSize} * 100)
						if (defined $sizeisnumber && $sizeisnumber && $entry->{hrStorageSize} != 0);

				$entry->{hrStorageTotal} = getDiskBytes($entry->{hrStorageUnits} * $entry->{hrStorageSize})
						if (defined $sizeisnumber && $sizeisnumber && $entry->{hrStorageUnits});

				my $usedisnumber = ($entry->{hrStorageUsed}
														&& $entry->{hrStorageUsed} =~ /^([+-]?)(?=\d|\.\d)\d*(\.\d*)?([Ee]([+-]?\d+))?$/ );
				$entry->{hrStorageUsage} = getDiskBytes($entry->{hrStorageUnits} * $entry->{hrStorageUsed})
						if (defined $usedisnumber && $usedisnumber && $entry->{hrStorageUnits});

				$entry->{hrStorageTypeName} = $typeName;

				my @summary;
				push(@summary,"Size: $entry->{hrStorageTotal}<br/>") if ($sizeisnumber);
				push(@summary,"Used: $entry->{hrStorageUsage} ($entry->{hrStorageUtil}%)<br/>") if ($usedisnumber);
				push(@summary,"Partition: $entry->{hrPartitionLabel}<br/>") if defined $entry->{hrPartitionLabel};

				$entry->{hrStorageSummary} = join(" ",@summary);
			}
		}

		if ( ref($Host_Memory) eq "HASH" ) {
			# lets calculate the available memory
			# https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/5/html/tuning_and_optimizing_red_hat_enterprise_linux_for_oracle_9i_and_10g_databases/chap-oracle_9i_and_10g_tuning_guide-memory_usage_and_page_cache
			# So available total is the physical memory total
			$Host_Memory->{available_total} = $Host_Memory->{physical_total};
			$Host_Memory->{available_units} = $Host_Memory->{physical_units};

			# available used is the physical used but subtract the cached and buffer memory which is available for use.
			$Host_Memory->{available_used} = $Host_Memory->{physical_used} - $Host_Memory->{cached_used} - $Host_Memory->{buffers_used} if defined $Host_Memory->{physical_used} and $Host_Memory->{buffers_used};
			# we don't need total for cache, buffers and available as it is really physical
			# the units all appear to be the same so just keeping physical
			my $rrddata = {
				'physical_total' => { "option" => "GAUGE,0:U", "value" => $Host_Memory->{physical_total}},
				'physical_used' => { "option" => "GAUGE,0:U", "value" => $Host_Memory->{physical_used}},
				'physical_units' => { "option" => "GAUGE,0:U", "value" => $Host_Memory->{physical_units}},
				'available_used' => { "option" => "GAUGE,0:U", "value" => $Host_Memory->{available_used}},
				'cached_used' => { "option" => "GAUGE,0:U", "value" => $Host_Memory->{cached_used}},
				'buffers_used' => { "option" => "GAUGE,0:U", "value" => $Host_Memory->{buffers_used}},
				'virtual_total' => { "option" => "GAUGE,0:U", "value" => $Host_Memory->{virtual_total}},
				'virtual_used' => { "option" => "GAUGE,0:U", "value" => $Host_Memory->{virtual_used}},
				'swap_total' => { "option" => "GAUGE,0:U", "value" => $Host_Memory->{swap_total}},
				'swap_used' => { "option" => "GAUGE,0:U", "value" => $Host_Memory->{swap_used}},

				#'buffers_total' => { "option" => "GAUGE,0:U", "value" => $Host_Memory->{buffers_total}},
				#'cached_total' => { "option" => "GAUGE,0:U", "value" => $Host_Memory->{cached_total}},
			};

			# updateRRD subrutine is called from rrdfunc.pm module
			my $updatedrrdfileref = updateRRD(data=>$rrddata, sys=>$S, type=>"Host_Memory", index => undef);

			# check for RRD update errors
			if (!$updatedrrdfileref) { info("Update RRD failed!") };

			info("Host_Memory total=$Host_Memory->{physical_total} physical=$Host_Memory->{physical_used} available=$Host_Memory->{available_used} cached=$Host_Memory->{cached_used} buffers=$Host_Memory->{buffers_used} to $updatedrrdfileref") if ($updatedrrdfileref);
			dbg("Host_Memory Object: ". Dumper($Host_Memory),1);
		}
	}

	return ($changesweremade,undef); # report if we changed anything
}

sub update_plugin
{
	my (%args) = @_;
	my ($node,$S,$C) = @args{qw(node sys config)};

	my $NI = $S->ndinfo;

	# anything to do?
	my $changesweremade = 0;

	# if there is EntityMIB data then load map out the entPhysicalVendorType to the vendor type fields
	# store in the field called Type.
	my $mibs = undef;
	if (ref($NI->{Host_Storage}) eq "HASH") {
		info("Working on $node Host_Storage");

		$mibs = loadMibs($C);

		for my $index (keys %{$NI->{Host_Storage}})
		{
			my $entry = $NI->{Host_Storage}{$index};

			if ( defined $entry->{hrStorageType} and defined $mibs->{$entry->{hrStorageType}} and $mibs->{$entry->{hrStorageType}} ne "" ) {
				$entry->{hrStorageTypeOid} = $entry->{hrStorageType};
				$entry->{hrStorageType} = $mibs->{$entry->{hrStorageType}};
				$changesweremade = 1;
			}
			else {
				dbg("Host_Storage no name found for $entry->{hrStorageType}",1) if defined $entry->{hrStorageType};
			}
		}
	}

	#  hrFSTypeOid

	if (ref($NI->{Host_File_System}) eq "HASH") {
		info("Working on $node Host_File_System");

		$mibs = loadMibs($C) if not defined $mibs;

		for my $index (keys %{$NI->{Host_File_System}})
		{
			my $entry = $NI->{Host_File_System}{$index};

			if ( defined $entry->{hrFSType} and defined $mibs->{$entry->{hrFSType}} and $mibs->{$entry->{hrFSType}} ne "" ) {
				$entry->{hrFSTypeOid} = $entry->{hrFSType};
				$entry->{hrFSType} = $mibs->{$entry->{hrFSType}};
				$changesweremade = 1;
			}
			else {
				dbg("Host_File_System no name found for $entry->{hrFSType}",1);
			}

			# lets cross link the file system to the storage.
			if ( defined $NI->{Host_Storage}{$entry->{hrFSStorageIndex}}{hrStorageDescr} ) {
				$entry->{hrStorageDescr} = $NI->{Host_Storage}{$entry->{hrFSStorageIndex}}{hrStorageDescr};
				$entry->{hrStorageDescr_url} = "/cgi-nmis8/network.pl?conf=$C->{conf}&act=network_system_health_view&section=Host_Storage&node=$node";
				$entry->{hrStorageDescr_id} = "node_view_$node";
				$changesweremade = 1;
			}

		}
	}

	if (ref($NI->{Host_Partition}) eq "HASH") {
		info("Working on $node Host_Partition");

		$mibs = loadMibs($C) if not defined $mibs;

		for my $index (keys %{$NI->{Host_Partition}})
		{
			my $entry = $NI->{Host_Partition}{$index};

			# lets cross link the partition to the file system and to the storage.

			if ( $entry->{hrPartitionFSIndex} >= 0 and defined $NI->{Host_File_System}{$entry->{hrPartitionFSIndex}}{hrFSIndex} ) {

				# this partition has the file system index of hrFSIndex
				my $hrFSIndex = $NI->{Host_File_System}{$entry->{hrPartitionFSIndex}}{hrFSIndex};
				# that file syste, has the storage index of hrFSStorageIndex
				my $hrFSStorageIndex = $NI->{Host_File_System}{$hrFSIndex}{hrFSStorageIndex};

				$entry->{hrStorageDescr} = $NI->{Host_Storage}{$hrFSStorageIndex}{hrStorageDescr};
				$entry->{hrStorageDescr_url} = "/cgi-nmis8/network.pl?conf=$C->{conf}&act=network_system_health_view&section=Host_Storage&node=$node";
				$entry->{hrStorageDescr_id} = "node_view_$node";
				$changesweremade = 1;

				# lets push some data into Host_Storage now
				$NI->{Host_Storage}{$hrFSStorageIndex}{hrPartitionLabel} = $entry->{hrPartitionLabel};
			}

		}
	}

	return ($changesweremade,undef); # report if we changed anything
}

sub loadMibs {
	my $C = shift;

	my $oids = "$C->{mib_root}/nmis_mibs.oid";
	my $mibs;

	info("Loading Vendor OIDs from $oids");

	open(OIDS,$oids) or warn "ERROR could not load $oids: $!\n";

	my $match = qr/\"([\w\-\.]+)\"\s+\"([\d+\.]+)\"/;

	while (<OIDS>) {
		if ( $_ =~ /$match/ ) {
			$mibs->{$2} = $1;
		}
		elsif ( $_ =~ /^#|^\s+#/ ) {
			#all good comment
		}
		else {
			info("ERROR: no match $_");
		}
	}
	close(OIDS);

	return ($mibs);
}

1;
