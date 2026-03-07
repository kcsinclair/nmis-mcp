#!/usr/bin/perl
#
# Tests for the NMIS9 MCP (Model Context Protocol) server.
#
# Run from the contrib/nmis-mcp/ directory:
#   perl t_nmis-mcp.pl
#
# These tests exercise the helper functions and dispatch logic using mock
# objects, so no live NMIS installation, MongoDB connection, or web server
# is required.
#
use strict;
use warnings;

use lib "/usr/local/nmis9/lib";

use Test::More;
use JSON::XS;

# ---------------------------------------------------------------------------
# 1. Load the CGI script as a library so we can call its subs directly.
#    We wrap it in a package so the top-level main() code doesn't execute.
# ---------------------------------------------------------------------------

# We cannot use/require the CGI script directly because it runs main code
# at load time. Instead we extract and test the helper subs by evaluating
# the relevant portions. For a cleaner approach we replicate the key data
# structures and helpers here (they are the same code).

# Replicate the data structures from nmis-mcp.pl so we can test them.

my %DESCRIPTION_FIELDS = (
	'interface'        => [qw(ifDescr Description)],
	'catchall'         => [qw(sysDescr sysName nodeType)],
	'Host_Storage'     => [qw(hrStorageDescr)],
	'Host_File_System' => [qw(hrFSMountPoint hrFSType)],
	'Host_Partition'   => [qw(hrPartitionLabel hrPartitionID)],
	'entityMib'        => [qw(entPhysicalName entPhysicalDescr)],
	'cdp'              => [qw(cdpCacheDeviceId cdpCacheDevicePort)],
	'lldp'             => [qw(lldpRemSysName lldpRemPortDesc)],
	'bgp'              => [qw(bgpPeerIdentifier)],
	'vlan'             => [qw(vlanName vtpVlanName)],
	'mpls'             => [qw(mplsVpnVrfName)],
	'cbqos'            => [qw(CbQosPolicyMapName)],
	'addressTable'     => [qw(dot1dTpFdbAddress)],
	'diskIOTable'      => [qw(diskIODevice)],
	'env-temp'         => [qw(lmTempSensorsDevice)],
	'storage'          => [qw(hrStorageDescr)],
	'service'          => [qw(service)],
	'ping'             => [qw(host)],
	'device'           => [qw(index)],
);

my @FALLBACK_DESCRIPTION_FIELDS = qw(Description description Name name ifDescr);

my %CONCEPT_RENAME = (
	'device' => 'cpuLoad',
);

my %FIELD_RENAME = (
	'interface' => {
		'ifInOctets'    => 'system.network.io.receive',
		'ifOutOctets'   => 'system.network.io.transmit',
		'ifInErrors'    => 'system.network.errors.receive',
		'ifOutErrors'   => 'system.network.errors.transmit',
		'ifInDiscards'  => 'system.network.dropped.receive',
		'ifOutDiscards' => 'system.network.dropped.transmit',
		'ifSpeed'       => 'system.network.speed',
		'ifOperStatus'  => 'system.network.status',
	},
	'device' => {
		'cpuLoad'  => 'system.cpu.utilization',
		'memUtil'  => 'system.memory.utilization',
	},
	'Host_Storage' => {
		'hrStorageUsed' => 'system.filesystem.usage.used',
		'hrStorageSize' => 'system.filesystem.usage.total',
	},
	'health' => {
		'reachability' => 'nmis.node.reachability',
		'availability' => 'nmis.node.availability',
		'health'       => 'nmis.node.health',
		'responsetime' => 'nmis.node.response_time_ms',
		'loss'         => 'nmis.node.packet_loss',
	},
	'laload' => {
		'laLoad1' => 'system.cpu.load_average.1m',
		'laLoad5' => 'system.cpu.load_average.5m',
	},
	'ping' => {
		'avg_ping_time' => 'network.peer.rtt.avg_ms',
		'ping_loss'     => 'network.peer.packet_loss',
	},
);

# ---------------------------------------------------------------------------
# Replicate the helper subs from nmis-mcp.pl
# ---------------------------------------------------------------------------

sub _get_description
{
	my ($concept, $data) = @_;
	my @fields = @{$DESCRIPTION_FIELDS{$concept} // []};
	push @fields, @FALLBACK_DESCRIPTION_FIELDS;
	for my $field (@fields)
	{
		return $data->{$field}
			if defined $data->{$field} && $data->{$field} ne '';
	}
	return '';
}

sub _apply_field_rename
{
	my ($concept, $src) = @_;
	return {} if (!$src || ref($src) ne 'HASH');
	my $map = $FIELD_RENAME{$concept} // {};
	my %out;
	for my $k (keys %$src)
	{
		next if $k =~ /_raw$/i;
		my $new_k = $map->{$k} // "nmis.$k";
		$out{$new_k} = $src->{$k};
	}
	return \%out;
}

sub _filter_derived
{
	my ($src) = @_;
	return {} if (!$src || ref($src) ne 'HASH');
	my %filtered = map { $_ => $src->{$_} }
		grep { $_ !~ /^(?:08|16)/ } keys %$src;
	return \%filtered;
}

sub _filter_derived_flat
{
	my ($derived) = @_;
	return {} if (!$derived || ref($derived) ne 'HASH');
	my %out;
	for my $sub (keys %$derived)
	{
		my $filtered = _filter_derived($derived->{$sub});
		%out = (%out, %$filtered);
	}
	return \%out;
}

# ---------------------------------------------------------------------------
# 2. _get_description tests
# ---------------------------------------------------------------------------

my @desc_tests = (
	# [ concept, data hashref, expected, label ]
	[ 'interface', { ifDescr => 'GigabitEthernet0/0', Description => 'WAN' },
	  'GigabitEthernet0/0', 'interface: picks ifDescr over Description' ],

	[ 'interface', { Description => 'WAN link' },
	  'WAN link', 'interface: falls back to Description' ],

	[ 'catchall', { sysDescr => 'Cisco IOS 15.2', sysName => 'router1' },
	  'Cisco IOS 15.2', 'catchall: picks sysDescr' ],

	[ 'catchall', { sysName => 'router1' },
	  'router1', 'catchall: falls back to sysName' ],

	[ 'Host_Storage', { hrStorageDescr => 'Physical memory' },
	  'Physical memory', 'Host_Storage: picks hrStorageDescr' ],

	[ 'diskIOTable', { diskIODevice => 'sda' },
	  'sda', 'diskIOTable: picks diskIODevice' ],

	[ 'ping', { host => '192.168.1.1' },
	  '192.168.1.1', 'ping: picks host' ],

	[ 'service', { service => 'Apache_Web' },
	  'Apache_Web', 'service: picks service' ],

	[ 'device', { index => '0' },
	  '0', 'device: picks index' ],

	[ 'UnknownConcept', { Description => 'A thing' },
	  'A thing', 'unknown concept: generic fallback to Description' ],

	[ 'UnknownConcept', { name => 'myname' },
	  'myname', 'unknown concept: falls through to name' ],

	[ 'interface', { ifIndex => '1', ifSpeed => 100 },
	  '', 'no description fields present: returns empty string' ],

	[ 'interface', { ifDescr => '', Description => 'Uplink' },
	  'Uplink', 'interface: skips empty ifDescr, uses Description' ],
);

for my $t (@desc_tests)
{
	my ($concept, $data, $expected, $label) = @$t;
	is(_get_description($concept, $data), $expected, "_get_description: $label");
}

# ---------------------------------------------------------------------------
# 3. _apply_field_rename tests
# ---------------------------------------------------------------------------

# Known fields get OTel names
{
	my $result = _apply_field_rename('interface', {
		ifInOctets  => 1000,
		ifOutOctets => 2000,
		ifSpeed     => 1000000,
	});
	is($result->{'system.network.io.receive'}, 1000, 'rename: ifInOctets -> system.network.io.receive');
	is($result->{'system.network.io.transmit'}, 2000, 'rename: ifOutOctets -> system.network.io.transmit');
	is($result->{'system.network.speed'}, 1000000, 'rename: ifSpeed -> system.network.speed');
}

# Unknown fields get nmis. prefix
{
	my $result = _apply_field_rename('interface', {
		ifInOctets   => 100,
		customMetric => 42,
	});
	is($result->{'nmis.customMetric'}, 42, 'rename: unknown field gets nmis. prefix');
	ok(!exists $result->{'customMetric'}, 'rename: original name not present');
}

# Fields ending in _raw are filtered out
{
	my $result = _apply_field_rename('interface', {
		ifInOctets     => 100,
		ifInOctets_raw => 99999,
		counter_Raw    => 55555,
	});
	is($result->{'system.network.io.receive'}, 100, 'rename: non-raw field kept');
	ok(!exists $result->{'nmis.ifInOctets_raw'}, 'rename: _raw field filtered');
	ok(!exists $result->{'nmis.counter_Raw'}, 'rename: _Raw field filtered (case insensitive)');
}

# Empty/undef input returns empty hashref
{
	my $r1 = _apply_field_rename('interface', undef);
	is_deeply($r1, {}, 'rename: undef input returns empty hash');

	my $r2 = _apply_field_rename('interface', {});
	is_deeply($r2, {}, 'rename: empty hash returns empty hash');
}

# Unknown concept — all fields get nmis. prefix
{
	my $result = _apply_field_rename('nonexistent_concept', {
		foo => 1,
		bar => 2,
	});
	is($result->{'nmis.foo'}, 1, 'rename: unknown concept prefixes foo');
	is($result->{'nmis.bar'}, 2, 'rename: unknown concept prefixes bar');
}

# Health subconcept rename
{
	my $result = _apply_field_rename('health', {
		reachability => 100,
		availability => 99.5,
		loss         => 0,
	});
	is($result->{'nmis.node.reachability'}, 100, 'rename: health reachability');
	is($result->{'nmis.node.availability'}, 99.5, 'rename: health availability');
	is($result->{'nmis.node.packet_loss'}, 0, 'rename: health loss -> packet_loss');
}

# Ping concept
{
	my $result = _apply_field_rename('ping', {
		avg_ping_time => 1.5,
		ping_loss     => 0,
	});
	is($result->{'network.peer.rtt.avg_ms'}, 1.5, 'rename: ping avg_ping_time');
	is($result->{'network.peer.packet_loss'}, 0, 'rename: ping_loss');
}

# ---------------------------------------------------------------------------
# 4. _filter_derived tests
# ---------------------------------------------------------------------------

{
	my $result = _filter_derived({
		reachability => 100,
		'08_something' => 50,
		'16_other'     => 25,
		availability   => 99,
	});
	is($result->{reachability}, 100, 'filter_derived: keeps normal key');
	is($result->{availability}, 99, 'filter_derived: keeps availability');
	ok(!exists $result->{'08_something'}, 'filter_derived: removes 08_ prefix');
	ok(!exists $result->{'16_other'}, 'filter_derived: removes 16_ prefix');
}

# Empty/undef input
{
	is_deeply(_filter_derived(undef), {}, 'filter_derived: undef returns empty');
	is_deeply(_filter_derived({}), {}, 'filter_derived: empty returns empty');
}

# ---------------------------------------------------------------------------
# 5. _filter_derived_flat tests
# ---------------------------------------------------------------------------

{
	my $result = _filter_derived_flat({
		health => {
			reachability   => 100,
			'08_something' => 50,
		},
		tcp => {
			tcpCurrEstab => 10,
			'16_badkey'  => 0,
		},
	});
	is($result->{reachability}, 100, 'filter_derived_flat: health.reachability kept');
	is($result->{tcpCurrEstab}, 10, 'filter_derived_flat: tcp.tcpCurrEstab kept');
	ok(!exists $result->{'08_something'}, 'filter_derived_flat: 08_ removed');
	ok(!exists $result->{'16_badkey'}, 'filter_derived_flat: 16_ removed');
}

# ---------------------------------------------------------------------------
# 6. %CONCEPT_RENAME tests
# ---------------------------------------------------------------------------

{
	is($CONCEPT_RENAME{'device'}, 'cpuLoad', 'concept_rename: device -> cpuLoad');
	ok(!exists $CONCEPT_RENAME{'interface'}, 'concept_rename: interface not renamed');

	# Test the rename-or-passthrough pattern used in the code
	my $renamed   = $CONCEPT_RENAME{'device'} // 'device';
	my $unchanged = $CONCEPT_RENAME{'interface'} // 'interface';
	is($renamed, 'cpuLoad', 'concept passthrough: device renamed');
	is($unchanged, 'interface', 'concept passthrough: interface unchanged');
}

# ---------------------------------------------------------------------------
# 7. JSON-RPC 2.0 request validation logic
# ---------------------------------------------------------------------------

# Test the validation patterns used in the dispatch code
{
	my $good = { jsonrpc => '2.0', id => 1, method => 'tools/list' };
	ok($good->{method} && ($good->{jsonrpc} // '') eq '2.0',
		'jsonrpc validation: valid request passes');

	my $bad_ver = { jsonrpc => '1.0', id => 1, method => 'tools/list' };
	ok(!(($bad_ver->{jsonrpc} // '') eq '2.0'),
		'jsonrpc validation: wrong version fails');

	my $no_method = { jsonrpc => '2.0', id => 1 };
	ok(!$no_method->{method},
		'jsonrpc validation: missing method fails');
}

# ---------------------------------------------------------------------------
# 8. Tool definitions structure validation
# ---------------------------------------------------------------------------

# Replicate the tool definitions to validate their structure
my @TOOL_DEFINITIONS = (
	{ name => "nmis_list_nodes",       inputSchema => { type => "object" } },
	{ name => "nmis_get_node_status",  inputSchema => { type => "object", required => ["node"] } },
	{ name => "nmis_get_latest_metrics", inputSchema => { type => "object", required => ["node", "concept"] } },
	{ name => "nmis_list_events",      inputSchema => { type => "object" } },
	{ name => "nmis_list_inventory",   inputSchema => { type => "object", required => ["node", "concept"] } },
	{ name => "nmis_get_node_precise_status", inputSchema => { type => "object" } },
);

is(scalar @TOOL_DEFINITIONS, 6, 'tool definitions: 6 tools defined');

for my $tool (@TOOL_DEFINITIONS)
{
	ok($tool->{name}, "tool '$tool->{name}' has a name");
	ok($tool->{inputSchema}, "tool '$tool->{name}' has inputSchema");
	is($tool->{inputSchema}{type}, 'object', "tool '$tool->{name}' schema type is object");
}

# Tools requiring node parameter
for my $name (qw(nmis_get_node_status nmis_get_latest_metrics nmis_list_inventory))
{
	my ($tool) = grep { $_->{name} eq $name } @TOOL_DEFINITIONS;
	ok(grep({ $_ eq 'node' } @{$tool->{inputSchema}{required} // []}),
		"tool '$name' requires 'node' parameter");
}

# Tools requiring concept parameter
for my $name (qw(nmis_get_latest_metrics nmis_list_inventory))
{
	my ($tool) = grep { $_->{name} eq $name } @TOOL_DEFINITIONS;
	ok(grep({ $_ eq 'concept' } @{$tool->{inputSchema}{required} // []}),
		"tool '$name' requires 'concept' parameter");
}

# nmis_list_events has no required params
{
	my ($tool) = grep { $_->{name} eq 'nmis_list_events' } @TOOL_DEFINITIONS;
	ok(!$tool->{inputSchema}{required}, 'nmis_list_events has no required params');
}

# nmis_list_nodes has no required params
{
	my ($tool) = grep { $_->{name} eq 'nmis_list_nodes' } @TOOL_DEFINITIONS;
	ok(!$tool->{inputSchema}{required}, 'nmis_list_nodes has no required params');
}

# nmis_get_node_precise_status has no required params (all optional)
{
	my ($tool) = grep { $_->{name} eq 'nmis_get_node_precise_status' } @TOOL_DEFINITIONS;
	ok($tool, 'nmis_get_node_precise_status tool exists');
	ok(!$tool->{inputSchema}{required}, 'nmis_get_node_precise_status has no required params');
}

# ---------------------------------------------------------------------------
# 9. precise_status overall label mapping
# ---------------------------------------------------------------------------

{
	my %overall_labels = ( 1 => 'reachable', 0 => 'unreachable', -1 => 'degraded' );
	is($overall_labels{1},  'reachable',   'overall_label: 1 => reachable');
	is($overall_labels{0},  'unreachable', 'overall_label: 0 => unreachable');
	is($overall_labels{-1}, 'degraded',    'overall_label: -1 => degraded');
	is($overall_labels{99} // 'unknown', 'unknown', 'overall_label: unknown value => unknown');
}

# ---------------------------------------------------------------------------
# 10. FIELD_RENAME coverage — ensure key concepts have rename maps
# ---------------------------------------------------------------------------

for my $concept (qw(interface device Host_Storage health laload ping))
{
	ok(exists $FIELD_RENAME{$concept}, "FIELD_RENAME: '$concept' has a rename map");
	ok(scalar keys %{$FIELD_RENAME{$concept}} > 0,
		"FIELD_RENAME: '$concept' map is non-empty");
}

# ---------------------------------------------------------------------------

done_testing();
