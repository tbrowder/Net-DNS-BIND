#!/usr/bin/env perl6
#
#
#    Copyright (c) 2010, Andris Kalnozols <andris@hpl.hp.com>
#
#    Permission to use, copy, modify, and/or distribute this software for any
#    purpose with or without fee is hereby granted, provided that the above
#    copyright notice and this permission notice appear in all copies.
#
#    THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
#    WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
#    MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
#    ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
#    WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
#    ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
#    OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
#
#
#    Originally written by Paul Albitz and Ken Stone of Hewlett-Packard
#    h2n-hp,v 1.96 1999/12/02 22:05:56 milli (Michael Milligan), Hewlett-Packard
#    Extended to v 2.61rc8 2010-08-31 by Andris Kalnozols, HP Labs
#
# NAME
#
#    h2n.p6      - Translate host table to name server file format
#    delegate.p6 - Create/check delegation information (zone linkage)
#
# SYNOPSIS
#
#    h2n.p6      -d DOMAIN -n NET -u CONTACT [options]
#    delegate.p6 -d DOMAIN -n NET -u CONTACT [options]
#

#use Cwd;		# for calling `getcwd'
#use FileHandle;		# for calling `autoflush'
#use Symbol;		# for calling `qualify'
#use Sys::Hostname;	# for calling `hostname'

# Various defaults
#
my $VERSION = "2.61rc8";
my $Program = $0;
   $Program ~~ s/.*\///;
my $Delegate = ($Program ~~ /delegate/ ?? 1 !! 0);
my $Host = hostname();
my $Do_CNAME = 1;
my $Do_MX = "[mx]";
my $Do_Zone_Apex_MX = 0;
my $Do_WKS = 0;
my $Do_TXT = 0;
my $Quoted_Txt_Preferred = 0;
my $Quoted_Txt_Only = 0;
my $Do_RP = 0;
my $Bootfile = "named.boot";
my $Conffile = "named.conf";
my $New_Fmt_Conffile = 0;
my $Conf_Prefile = "";
my $Hostfile = "/etc/hosts";
my $Commentfile = "";
my $Domain = "";
my $Domainfile = "";
my $RespHost = "";
my $RespUser = "";
my $DefSerial = 1;
my $DefRefresh = "3H";
my $DefRetry = "1H";
my $DefExpire = "1W";
my $DefNegCache = "10M";
my $DefTtl = "1D";
my $Need_Numeric_Ttl = 0;
my $DefMXWeight = 10;
my $Defsubnetmask = "255.255.255.0";
my $Supernetting_Enabled = 0;
my $ReportNonMatchingDomains = 1;
my $UseDefaultDomain = 0;
my $UseDateInSerial = 0;
my $Print_Sequence = 0;
my $Open_DB_Files = 0;
my $Open_File_Limit = 120;
my $Verbose = 1;
my $Gen_Count = 0;
my $CustomLogging = 0;
my $CustomOptions = 0;
my $NeedHints = 1;
my $Multi_Homed_Mode = "";
my $Check_Level = "audit";
my $RFC_952 = 0;	   # NOTE: Don't set true unless $RFC_1123 is also true.
my $RFC_1123 = 1;
my $RFC_2308 = 1;	   # New default as of version 2.40
my $RFC_2782 = 0;
my $Audit = 1;		   # DNS auditing is independent of RFC name checking.
my $DefAction = "Warning"; # Default action to take if hostnames aren't perfect.
my $Load_Status = 0;	   # Set true by READ_RRs() if BIND won't load the zone.
my $Newline_Printed = 0;
my $Preserve_Case = 0;
my $Verify_Mode = 0;
my $Recursive_Verify = 0;
my $Recursion_Depth = 0;
my $Verify_Delegations = 1;
my $Show_Single_Delegations = 1;
my $Query_External_Domains = 1;
my $Show_Chained_CNAMEs = 0;
my $Debug = 0;
my $Debug_DIR = "/tmp";
my $Glueless_Upper_Limit = 30;
my $Display_Glueless_Limit = 0;
my $Valid_SOA_Timers = 1;
my $Localhost = "127.0.0.1";
my $MakeLoopbackSOA = 1;
my $MakeLoopbackZone = 1;
my $Owner_Field = "";
my $RCfile = "";
my $Conf_Only = 0;


# ---------------------------------------------------------------------------
#
#   Default values for settings that can be customized on a site-specific
#   basis by means of a special `h2n.conf' configuration file that is
#   read at startup by the READ_RCFILE() subroutine.
#
#
# The following two data items are used in verify mode to create a sorted
# list of best possible name servers from which a zone transfer is requested.
# This helps to avoid unnecessary delays by trying name servers on local
# networks first.  The corresponding keyword in the configuration file is
# "LOCAL-NETWORKS".
#
# * The "@Local_Networks" array should be initialized to the list of
#   network(s) (in CIDR format) to which the localhost is connected,
#   e.g., a dual-homed localhost should have two entries in this array.
# * The "@Local_Subnetmasks" array should be initialized to the subnet
#   mask(s) which correspond to the network(s) in "@Local_Networks".
#
my @Local_Networks    = ("0/0");		# Set default network and mask
my @Local_Subnetmasks = ("0.0.0.0");		# for universal connectivity.

# The `h2n' program calls two external utilities, `DiG' and `check_del',
# to make various DNS queries.  The following two variables hold their
# filenames.  If not qualified with a pathname, the filename is expected
# to be found in the environment's search path, e.g., if `h2n' is run
# via cron(1M), the default PATH is usually "/usr/bin:/usr/sbin:.".
# The corresponding keywords in the configuration file are "DIG-UTILITY"
# and "CHECK_DEL-UTILITY".
#
my $DiG       = "/usr/local/bin/dig";
my $Check_Del = "/usr/local/bin/check_del";

# The DiG utility is rather patient in the time it will wait for a
# response before giving up on a name server in an NS RRset (4 seconds
# for versions 2-8.X and 5 seconds for 9.X versions).  It's also
# rather generous in the number of times each name server is retried
# (4 times for 2-8.X versions and 3 times for 9.X versions).
# There is a potential for significant delays when auditing domain
# names that point to unreachable name servers.  The following two
# variables allow these DiG parameters to be customized.
# The corresponding keywords in the configuration file are
# "DIG-TIMEOUT-LIMIT" and "DIG-RETRY-LIMIT".
#
my $DiG_Timeout = 4;
my $DiG_Retries = 2;

# The traditional advice for glue records is to use them only when
# absolutely necessary (the name server for a delegated subzone is
# itself in the subzone being delegated) and to avoid the gratuitous
# addition of glue that is not mandatory as an ad hoc, "just to be sure"
# measure.  Since glue must be kept synchronized with its authoritative
# counterparts in the delegated subzone just like the NS RRsets, this
# is usually good advice.
#
# However, name resolution suffers in the real world when sensible
# limits of recursive ("glueless") delegations are exceeded.  The
# following two variables allow for a conservative limit to be placed
# on recursive delegations that `h2n' finds in a `spcl' file when
# building zone data and a more liberal limit when verifying existing
# DNS zone data.  The corresponding keywords in the configuration file
# are "DB-GLUELESS-LIMIT" and "VERIFY-GLUELESS-LIMIT".
#
# These default values are mentioned in Section 2.3 of the document
# "Observed DNS Resolution Misbehavior" which is available online at
# < http://www.ietf.org/internet-drafts/ > as the text file
# `draft-ietf-dnsop-bad-dns-res-03.txt'.
#
my $DB_Glueless_Limit     = 1;
my $Verify_Glueless_Limit = 3;

#
# ---------------------------------------------------------------------------


# To increase the processing speed of the READ_RRs subroutine, arrange the
# set of recognized RR types in order of decreasing frequency, i.e.,
# the most common types of RRs should appear first.  There can be up to
# a 7% speed difference between best-case and worst-case ordering.
# IMPORTANT: Always use the "/o" modifier in patterns which contain the
#            static "$RRtypes" value to avoid needless recompilation
#            of the working pattern space.
#
# NOTE: * Per RFC-1035, the NULL RR is not allowed in master files and,
#         thus, the NULL RR is deliberately not recognized.
#       * Per RFC-1123, the obsolete MD and MF RR types are deliberately
#         not recognized.
#       * The meta-RRs OPT (RFC-2671), TSIG (RFC-2845), and TKEY (RFC-2930)
#         are recognized in case they appear in the output of utilities
#         such as DiG which this program may use.
#       * Per RFC-3755, the obsolete NXT record is deliberately
#         not recognized.
#
my $RRtypes = "MX|A|CNAME|PTR|NS|AAAA|HINFO|RP|TXT|SRV|SOA|KEY|NSAP|NSAP-PTR|"
	    . "NAPTR|AFSDB|RT|ISDN|X25|PX|LOC|CERT|KX|DNAME|WKS|M[BGR]|MINFO|"
	    . "EID|NIMLOC|ATMA|GPOS|APL|SINK|SSHFP|DHCID|SPF|HIP|RRSIG|NSEC|"
	    . "NSEC3|NSEC3PARAM|DS|DNSKEY|DLV|IPSECKEY|SIG|A6|TSIG|OPT|TKEY";

# Catalog the RFC-2535 DNSSEC RR types (KEY, NXT, and SIG), as well as their
# replacements from RFC-4034 (NSEC and RRSIG) that are allowed to share
# owner names with CNAMEs.
# Catalog the RFC-4034 DNSSEC RR types (NSEC and RRSIG), that are allowed
# to share owner names with CNAMEs.  Per RFC-3007, a KEY record for secure
# dynamic update purposes is also allowed to be present at a CNAME.
# IMPORTANT: Always use the "/o" modifier in patterns which contain the
#            static "$DNSSEC_RRtypes" value to avoid needless recompilation
#            of the working pattern space.
# NOTE: * Per RFC-3755, the original DNSSEC records from RFC-2535 (NXT
#         and SIG) are deliberately not recognized for DNSSEC purposes.
#
my $DNSSEC_RRtypes = "NSEC3?|RRSIG|KEY";

# Construct a table of BIND versions that are vulnerable to various bugs
# according to < http://www.isc.org/products/BIND/bind-security.html >.
# A warning will be displayed anytime `h2n' detects one of these versions.
# NOTE: The GET_BIND_VERSION() subroutine will also determine if any
#       of the following bugs should be reported as possibly present:
#
#         libbind buffer overflow
#         LIBRESOLV: buffer overrun
#         BIND: Multiple Denial of Service
#         BIND: Remote Execution of Code
#         BIND: Negative Cache DoS
#         BIND: q_usedns Array Overrun
#         BIND: Self Check Failing
#         OpenSSL buffer overflow
#         DoS internal consistency check
#
#
# NOTE: Make sure to keep the "$BIND_Bug_Titles" variable
#       current with the above list of BIND bug categories
#       that are added to the GET_BIND_VERSION() subroutine.
#
my $BIND_Bug_Titles = "libbind|LIBRESOLV|BIND|OpenSSL|DoS";

my %BIND_Bug_Index = (
 '4.8'	   => 'infoleak',
 '4.8.1'   => 'infoleak',
 '4.8.2.1' => 'infoleak',
 '4.8.3'   => 'infoleak',
 '4.9.3'   => 'complain infoleak',
 '4.9.4'   => 'complain infoleak',
 '4.9.4-P1'=> 'complain infoleak',
 '4.9.5'   => 'sig naptr maxdname complain infoleak',
 '4.9.5-P1'=> 'sig naptr maxdname complain infoleak',
 '4.9.6'   => 'sig naptr maxdname complain infoleak',
 '4.9.7'   => 'naptr maxdname complain infoleak',
 '4.9.8'   => 'naptr maxdname',
 '8.1'	   => 'sig naptr maxdname solinger fdmax infoleak',
 '8.1.1'   => 'sig naptr maxdname solinger fdmax infoleak',
 '8.1.2'   => 'naptr maxdname solinger fdmax infoleak',
 '8.1.3'   => 'naptr maxdname solinger fdmax infoleak',
 '8.2'	   => 'sigdiv0 srv nxt sig naptr maxdname solinger fdmax infoleak tsig',
 '8.2-P1'  => 'sigdiv0 srv nxt sig naptr maxdname solinger fdmax infoleak tsig',
 '8.2.1'   => 'sigdiv0 srv nxt sig naptr maxdname solinger fdmax infoleak tsig',
 '8.2.2'   => 'zxfr sigdiv0 srv naptr maxdname infoleak tsig',
 '8.2.2-P1'=> 'zxfr sigdiv0 srv naptr maxdname infoleak tsig',
 '8.2.2-P2'=> 'zxfr sigdiv0 srv infoleak tsig',
 '8.2.2-P3'=> 'zxfr sigdiv0 srv infoleak tsig',
 '8.2.2-P4'=> 'zxfr sigdiv0 srv infoleak tsig',
 '8.2.2-P5'=> 'zxfr sigdiv0 srv infoleak tsig',
 '8.2.2-P6'=> 'zxfr srv infoleak tsig',
 '8.2.2-P7'=> 'infoleak tsig',
 '8.2.2-P8'=> 'infoleak tsig',
 '8.2.3-T' => 'tsig'
);

# URLs that document the above-mentioned BIND bugs
#
my $CERT_URL_bugs      = "< http://www.cert.org/advisories/CA-2001-02.html >";
my $CERT_URL_DoS       = "< http://www.cert.org/advisories/CA-2002-15.html >";
my $CERT_URL_libbind   = "< http://www.cert.org/advisories/CA-2002-19.html >";
my $CERT_URL_openssl   = "< http://www.cert.org/advisories/CA-2002-23.html >";
my $CERT_URL_buf_DoS   = "< http://www.cert.org/advisories/CA-2002-31.html >";
my $CERT_URL_negcache  = "< http://www.kb.cert.org/vuls/id/734644 >";
my $CERT_URL_overrun   = "< http://www.kb.cert.org/vuls/id/327633 >";
my $CERT_URL_selfcheck = "< http://www.kb.cert.org/vuls/id/938617 >";
my $ISC_URL = "< http://www.isc.org/products/BIND/bind-security.html >";

my $IPv4_pattern =
            '^(?:(?:25[0-5]|(?:2[0-4]|1[0-9]|[1-9]?)[0-9])(?:[.](?=.)|\z)){4}$';

my $IPv6_pattern =
     '^((?=.*::.*)(::)?([0-9A-F]{1,4}(:(?=[0-9A-F])|(?!\2)(?!\5)(::)|\z)){0,7}|'
   . '((?=.*::.*)(::)?([0-9A-F]{1,4}(:(?=[0-9A-F])|(?!\7)(?!\10)(::))){0,5})|'
   . '(?:[0-9A-F]{1,4}:){7}[0-9A-F]{1,4})$';


my ($Audit_Domain, $BIND_Ver_Msg, $BIND_Version, $BIND_Version_Num, $Boot_Dir);
my ($BootSecAddr, $BootSecSaveAddr, $ConfSecAddr, $ConfSecSaveAddr, $DB_Dir);
my ($Data_Fname, $Debug_BIND_Version, $Del_File, $DiG_Bufsize);
my ($DiG_Version_Num, $Domain_Pattern, $Exit_Status, $Expire, $Glueless_Limit);
my ($Master_Ttl, $New_Serial, $Output_Msg, $Recursion_Limit, $Refresh, $Retry);
my ($SOA_Count, $Search_Dir, $Search_Display_Dir, $Show_Dangling_CNAMEs);
my ($Special_File, $Temp, $Ttl, $User);
my (%Aliases, %Apex_Aliases, %Apex_RRs, %Apex_Route_RRs, %Comment_RRs);
my (%Comments, %DB_Filehandle, %Dangling_CNAME_Domains, %Deferred_PTR);
my (%Ext_NS, %Hosts, %LRUtable, %MXlist, %Master_Zone_Opt, %NSlist);
my (%NSowners, %Net_Ranges, %Net_Zones, %PTR_Pat_Rel, %Partial_Servers);
my (%Pending_PTR, %RRowners, %Slave_Zone_Opt, %Spcl_AFSDB, %Spcl_CNAME);
my (%Spcl_PTR, %Spcl_RP, %Spcl_RT, %Spcl_SRV, %Wildcards, %c_Opt_Aliases);
my (%c_Opt_Pat_Rel, %c_Opt_Spec, %e_Opt_Pat_Exceptions, %p_Opt_Mode_Spec);
my (@Boot_Msgs, @Boot_Opts, @Conf_Logging, @Conf_Opts, @DNS_RRset);
my (@Dangling_CNAME_Domains, @Full_Servers, @Global_Master_Zone_Opts);
my (@Global_Slave_Zone_Opts, @MX, @Make_SOA, @Our_Addrs, @Our_Netbits);
my (@Our_Nets, @Our_Subnetmasks, @Our_Subnets, @V_Opt_Domains, @c_Opt_Patterns);
my (@e_Opt_Patterns, @p_Opt_Patterns);


autoflush STDOUT 1;		# Allows single-character output w/o newline.
autoflush STDERR 1;		# Keeps STDERR output synchronized with STDOUT.

READ_RCFILE();			# a way to override various built-in defaults
PARSE_ARGS(@ARGV);		# overrides any options found in a CONF file
FIXUP();
if ($Conf_Only) {
    #
    # We're only interested in generating the BIND
    # configuration files from the just-read options.
    #
    GEN_BOOT();
    exit;
}

$Audit = 0 if $Delegate;	# Prevent the following warning message if we
				# are generating a delegation report and DiG
				# version 9.0.0 happens to be in operation.

if ($DiG_Version_Num == 90000 && ($Verify_Mode || $Audit)) {
    ($Output_Msg = <<'EOT') ~~ s/^\s+\|//gm;
    |
    |The DiG utility found by `h2n' is version 9.0. It is unsupported
    |due to its inability to echo batch file input.  Please replace it
    |with another version of DiG from either BIND 8 or the most recent
    |distribution of BIND 9.
EOT
    unless ($Verify_Mode) {
	$Output_Msg .= "The auditing option has been disabled for this run.\n";
	$Audit = 0;
    }
    print STDERR "$Output_Msg\n";
    exit(2) if $Verify_Mode;
}
# NOTE: All versions of DiG 9.0.1, while usable by `h2n', have a small
#       defect whereby the command line is not echoed whenever any kind of
#       name server connection failure is encountered.  The AUDIT_RRs()
#       subroutine treats these detected cases as a general synchronization
#       failure when parsing the output from DiG and will generate a status
#       of "[sync. error ]" for the queried domain name.
#

if ($Verify_Mode) {		# If called with -V
    VERIFY_ZONE();
    exit 0;
}

if (!$RFC_2308 || $BIND_Version_Num < 80201) {
    #
    # When in doubt, convert time intervals that may be in symbolic
    # notation to the equivalent number of seconds.  This is the
    # universally understood format.
    #
    $Need_Numeric_Ttl = 1;
    $DefRefresh	 = SECONDS($DefRefresh);
    $DefRetry	 = SECONDS($DefRetry);
    $DefExpire	 = SECONDS($DefExpire);
    $DefNegCache = SECONDS($DefNegCache);
    $DefTtl	 = SECONDS($DefTtl);
    $Refresh	 = SECONDS($Refresh) if $Refresh;
    $Retry	 = SECONDS($Retry) if $Retry;
    $Expire	 = SECONDS($Expire) if $Expire;
    $Ttl	 = SECONDS($Ttl) if $Ttl;
    $Master_Ttl	 = SECONDS($Master_Ttl) if $Master_Ttl;
print "\nDEBUG Info: \$RFC_2308         = `$RFC_2308'\n";
print "            \$DiG_Version_Num  = `$DiG_Version_Num'\n";
print "            \$BIND_Version_Num = `$BIND_Version_Num'\n\n";
}

if ($Delegate) {		# If called as "delegate" or with -D
    DELEGATE_INFO();
    exit 0;
}

# If this point is reached, then we are going to generate one
# or more DNS zone data files from an RFC-982 HOSTS.TXT file.
#
# First, check the BIND version of the master name server in the
# "-h" option and issue any warnings about known vulnerabilities.
#
if ($BIND_Ver_Msg) {
    ($Temp = $RespHost) ~~ s/[.]$//;
    $BIND_Ver_Msg       ~~ s/ See /See /;
    $BIND_Ver_Msg       ~~ s/     </    </g;
    print STDERR "\nWarning: $Temp (-h option) is running BIND ",
		     "$BIND_Version.\n",
		     "This version of BIND may be vulnerable to the ",
		     "following bug(s):\n",
		     "$BIND_Ver_Msg\n\n";
}
print STDOUT "Initializing new database files...\n" if $Verbose;
INITDBs();
HOSTS_TO_RRs();
print STDOUT "Generating boot and conf files...\n" if $Verbose;
GEN_BOOT();
if ($Audit && $Verbose) {
    #
    # Take the opportunity to undefine some data structures that are
    # no longer needed.  The memory space can then be reused by the
    # AUDIT_RRs subroutine which itself needs to create still more
    # data structures.
    #
    undef %Aliases;
    undef %Comments;
    undef %Deferred_PTR;
    undef %Pending_PTR;
    undef %c_Opt_Aliases;
    undef %c_Opt_Spec;
    undef %p_Opt_Mode_Spec;
    undef %c_Opt_Pat_Rel;
    undef %PTR_Pat_Rel;
    undef %Comment_RRs if $Commentfile;
    undef %DB_Filehandle;
    undef %LRUtable;
    undef %Net_Ranges;
    undef %Net_Zones;
    undef %Master_Zone_Opt;
    undef %Slave_Zone_Opt;
    undef @Boot_Opts;
    undef @Conf_Logging;
    undef @Conf_Opts;
    undef @Global_Master_Zone_Opts;
    undef @Global_Slave_Zone_Opts;
    undef @Boot_Msgs;
    undef @c_Opt_Patterns;
    undef @p_Opt_Patterns;
    undef @e_Opt_Patterns;
    undef @Make_SOA;

    # As a paranoid exercise, make sure the "$Data_Fname" variable
    # undergoes the same sanitation as is performed in the VERIFY_ZONE
    # subroutine so that there are no nasty surprises with temporary
    # filenames that can't be created.
    #
    $Data_Fname = lc($Domain);		# override a -P option
    for ($Data_Fname) {
	s/\\([<|>&\(\)\$\?@;'`])/$1/g;	# unescape special characters
	s/[\/<|>&\[\(\)\$\?;'`]/%/g;	# change the problematic ones to "%"
	s/\\\s/_/g;			# change white space into underscores
	s/\\//g;			# remove remaining escape characters
    }

    print STDOUT "Checking NS, MX, and other RRs ",
		 "for various improprieties...\n";
    AUDIT_RRs(0);
}
if (($Load_Status == 2 && $DefAction eq "Skipping") || $Load_Status > 2) {
    ($Output_Msg = <<'EOT') ~~ s/^\s+\|//gm;
    |Attention! One or more of the above errors is sufficiently severe to
    |           either prevent the zone from being loaded or the bad data
    |           may cause interoperability problems with other name servers.
EOT
    print STDERR "$Output_Msg\n" if $Verbose;
    $Exit_Status = 1;
} else {
    $Exit_Status = 0;
}
print STDOUT "Done.\n" if $Verbose;
exit($Exit_Status);



#
# This is the primary subroutine when `h2n' is used to generate
# DNS data from a host file.  The host file will be read and
# processed according to the supplied `h2n' options.  Relevant
# `spcl' files will also be processed.  After every input file
# is accounted for, the appropriate "db.zone" files are created.
#
# Return value: void
#
sub HOSTS_TO_RRs {
    my ($a_len, $action, $addr, $addrpattern, $alias, $b_len, $c_opt_domain);
    my ($canonical, $cmode, $comment, $common_alias, $continue_search, $data);
    my ($default_ptr, $error, $first_ip, $ignore_c_opt, $key, $last_ip);
    my ($last_octet, $line_num, $make_rr, $match, $message, $names, $netpat);
    my ($p_opt_domain, $pmode, $ptr_file, $ptr_owner, $ptr_template, $ptrpat);
    my ($reformatted_line, $show, $show_host_line, $spcl_file, $tmp);
    my ($tmp_cmode, $tmp_netpat, $tmp_rfc_952, $tmp_uqdn, $ttl, $uqdn);
    my ($zone_name);
    my (%aliases_ptr, %hosts_ptr, %owner_ttl, %p_opt_ptr);
    my (@a_fields, @addrs, @aliases, @b_fields, @sorted_nets);

    if ($Preserve_Case) {
	#
	# Just as was done for certain global hashes in PARSE_ARGS(),
	# tie the local hashes that are related to zone file building
	# to the `Tie::CPHash' module.
	#
	tie %aliases_ptr, "Tie::CPHash";
	tie %hosts_ptr,   "Tie::CPHash";
	tie %owner_ttl,   "Tie::CPHash";
    }

    if (-r "$Search_Dir/$Special_File") {
	if ($Verbose) {
	    print STDOUT "Reading special file ",
			 "`$Search_Display_Dir/$Special_File'...\n";
	}
	# Make sure to disable checking of single-character hostnames and
	# aliases since this RFC-952 restriction is limited to host files.
	#
	$tmp_rfc_952 = $RFC_952;
	$RFC_952 = 0;

	# The "$Newline_Printed" variable controls the printing of cosmetic
	# newlines surrounding a block of warning messages that the
	# READ_RRs subroutine may generate.  "$Newline_Printed" is global
	# in scope to prevent unwanted extra newlines in case READ_RRs is
	# called recursively.  If necessary, the initial newline is output
	# within READ_RRs while the one or two terminating newline characters
	# are printed after the subroutine returns to its original caller.
	#
	$Newline_Printed = READ_RRs("$Search_Dir/$Special_File", "$Domain.",
				    "$Domain.", "$Domain.", 0);
	if ($Verbose) {
	    print STDERR "\n" while $Newline_Printed--;
	} else {
	    $Newline_Printed = 0;
	}
	$RFC_952 = $tmp_rfc_952;
    }

    if ($Verbose) {
	if ($Hostfile eq "-") {
	    print STDOUT "Reading hosts from STDIN...\n";
	} else {
	    print STDOUT "Reading host file `$Hostfile'...\n";
	}
    }
    unless (open(*HOSTS, '<', $Hostfile)) {
	print STDERR "Couldn't open the host file: $!\n",
		     "Check your -H option argument.\n";
	GIVE_UP();
    }
    $line_num = $show_host_line = 0;
    LINE: while (<HOSTS>) {
	$line_num++;
	chomp;					# Remove the trailing newline.
	chop if /\r$/;				# Remove carriage-returns also.
	next if /^#/ || /^$/;			# Skip comments and empty lines.
	($data, $comment) = split(/#/, $_, 2);	# Separate comments from the
	$comment = '' unless defined($comment);	# interesting bits.
	($addr, $names) = split(' ', $data, 2);	# Isolate IP addr. from name(s).
	$addr = '' unless defined($addr);	# Catch leading space typos.
	if ($addr ~~ /$IPv4_pattern/o) {
	    $message = "";
	} elsif ($addr !~ /:/) {
	    #
	    # The IPv4 address was incorrectly formatted.
	    #
	    $message = 'IPv4 address';
	} elsif ($addr ~~ /$IPv6_pattern/io) {
	    #
	    # Allow the valid IPv6 address to pass but
	    # do not process the entry any further until
	    # IPv6 is fully implemented by this program.
	    #
	    next;
	} else {
	    #
	    # The IPv6 address was incorrectly formatted.
	    #
	    $message = 'IPv6 address';
	}
	if ($message || !defined($names) || $names ~~ /^\s*$/) {
	    if ($Verbose) {
		if ($message && (!defined($names) || $names ~~ /^\s*$/)) {
		    $message = "data";
		} elsif (!$message && (!defined($names) || $names ~~ /^\s*$/)) {
		    $message = "hostname field";
		}
		print STDERR "Line $line_num: ",
			     "Skipping; incorrectly formatted $message.\n",
			     "> $_\n";
	    }
	    next LINE;
	}
	$names = lc($names) unless $Preserve_Case;

	# Process -e options
	#
	foreach $netpat (@e_Opt_Patterns) {
	    next if $names !~ /(?:^|[.])$netpat(?:\s|$)/i;
	    #
	    # If a -e domain happens to be a parent of the -d domain or
	    # a -c or -p domain, exit this loop and continue processing.
	    # Otherwise, fetch the next host file entry.
	    #
	    last if $names ~~ /$e_Opt_Pat_Exceptions{$netpat}/i;
	    next LINE;
	}

	if ($comment ~~ /\[\s*ttl\s*=\s*(\d+|(\d+[wdhms])+)\s*\]/i) {
	    $ttl = $1;				# set TTL if explicit
	    if ($Need_Numeric_Ttl) {		# and convert time
		$ttl = SECONDS($ttl);		# format if necessary
	    } else {
		$ttl = SYMBOLIC_TIME($ttl);
	    }
	} else {
	    $ttl = "";				# set TTL to implicit default
	}
	# Separate the canonical name from any aliases that follow.
	#
	($canonical, @aliases) = split(' ', $names);
	$error = CHECK_NAME($canonical, 'A');
	if ($error) {
	    $action = ($error == 3) ? "Skipping" : $DefAction;
	    if ($Verbose) {
		print STDERR "Line $line_num: $action; `$canonical' ",
			     "not a valid canonical hostname.\n";
		if ($action eq "Skipping") {
		    print STDERR "> $_\n";
		} else {
		    $show_host_line = 1;
		}
	    }
	    next LINE if $action eq "Skipping";
	}
	$reformatted_line = 0;

	# Process -c options
	#
	# If a `spcl' file exists for the `-d' domain, it has already been read.
	# The %RRowners hash now contains the discovered `spcl' and -T option
	# domain names and will be used to prevent the creation of conflicting
	# CNAMEs.  Checks are also made to prevent the accidental creation of
	# cross-domain wildcard CNAMEs in case "*" characters are lurking in
	# the host table.
	# NOTE: The "@c_Opt_Patterns" array has been sorted by the FIXUP()
	#       subroutine so that the deepest subtrees of each domain will
	#       be matched before their ancestors in the domain tree.
	#       CNAMES that are created immediately are done so on a
	#       "first match wins" basis.  For deferred CNAMEs, however,
	#       a name collision will be settled by the order in which
	#       the `-c' options appeared.  Earlier-specified `-c' domains
	#       will outrank those which were specified later even if the
	#       ranking domain is an ancestor in the same domain tree.
	#
	$cmode = "";
	foreach $netpat (@c_Opt_Patterns) {
	    next if $names !~ /[.]$netpat(?:\s|$)/i;
	    next LINE if $addr eq $Localhost;
	    $cmode = $c_Opt_Spec{$netpat}{MODE};
	    if ($cmode ~~ /O/) {
		#
		# The matched domain is a parent domain of the default
		# domain (-d option).  Make sure to override -c option
		# processing if the current host file entry also matches
		# the -d option domain.
		#
		if ($names ~~ /$Domain_Pattern(?:\s|$)/io) {
		    $cmode = "";
		    last;
		}
	    }
	    $c_opt_domain = $c_Opt_Pat_Rel{$netpat};
	    #
	    # Although the fully-qualified (canonical) host name
	    # is supposed to follow the IP address in a properly
	    # formatted host table, some sysadmins use the following
	    # style instead:
	    #
	    #   192.168.0.1   host1  host1.movie.edu  alias1  alias2 ...
	    #
	    # We'll accommodate this variation by comparing the
	    # canonical host name in the second name field against
	    # the unqualified host name (UQHN) in first field.
	    # If the only difference is the default domain name,
	    # the name columns will be left-shifted to eliminate the
	    # redundancy.  If the names don't match, however, the
	    # host file entry will likely fail to be processed; h2n
	    # will complain about the UQHN not matching the "-d"
	    # option due to the default expectation of an FQHN.
	    #
	    # Another common formatting style that is a more forgiving
	    # variation of the above is to have the UQHN follow the
	    # fully-qualified name as the first "alias":
	    #
	    #   192.168.0.1   host1.movie.edu  host1  alias1  alias2 ...
	    #
	    # If this is the case, the redundant UQHN will be eliminated.
	    # The reason that this is more forgiving is that a typo in the
	    # UQHN will still process the host file entry while rendering
	    # the non-matching UQHN to be processed as an extra alias.
	    # NOTE: The need for a UQHN field in `/etc/hosts' may still
	    #       be a requirement during the bootup of some operating
	    #       systems.  If this is the case at your site, it would
	    #       be better to keep a master version of the host file
	    #       _without_ the UQHNs for processing by h2n and distribute
	    #       a separate client version of the host file with the UQHNs
	    #       added by sed(1) or awk(1) [or perl(1)].
	    #
	    if (@aliases) {
		$data = ($cmode ~~ /I/) ? $Domain : $c_opt_domain;
		if (lc("$canonical.$data") eq lc($aliases[0])) {
		    $canonical = $aliases[0];
		    shift(@aliases);
		    $reformatted_line = 1;
		}
		if (@aliases && lc($canonical) eq lc("$aliases[0].$data")) {
		    shift(@aliases);
		    $reformatted_line = 1;
		}
	    }
	    ($uqdn = $canonical) ~~ s/[.]$netpat$//i;
	    $ignore_c_opt = 0;
	    if ($comment ~~ /\[\s*(?:no|ignore)\s*-c\s*\]/i) {
		$ignore_c_opt = 1;
	    } elsif ($cmode !~ /D/) {
		#
		# Create CNAMEs now, not later.
		#
		$show = 0;
		if ($cmode !~ /I/) {
		    #
		    # See if the external -c domain matches criteria
		    # from the `[-show|hide]-dangling-cnames' option.
		    #
		    $show = $Show_Dangling_CNAMEs;
		    if (@Dangling_CNAME_Domains) {
			foreach $tmp (@Dangling_CNAME_Domains) {
			    next if $c_opt_domain !~ /^$tmp$/i;
			    $show = $Dangling_CNAME_Domains{$tmp};
			    last;
			}
		    }
		}
		if ($c_opt_domain ~~ /$Domain_Pattern$/io) {
		    #
		    # Make the intra-zone/subzone domain name in the CNAME's
		    # RDATA field relative to the zone's origin (-d option).
		    #
		    $c_opt_domain ~~ s/$Domain_Pattern$//io;
		} else {
		    #
		    # Make the RDATA domain name absolute.
		    #
		    $c_opt_domain .= ".";
		}
		if (exists($RRowners{$uqdn})) {
		    #
		    # Accommodate any DNSSEC-related RRs from a `spcl'
		    # file that are allowed to co-exist with CNAMEs.
		    #
		    $match = $RRowners{$uqdn};
		    1 while $match ~~ s/ (?:$DNSSEC_RRtypes) / /go;
		} else {
		    $match = " ";
		}
		if ($match eq " " && $uqdn !~ /^\*(?:$|[.])/) {
		    PRINTF(*DOMAIN, "%s%s\tCNAME\t%s.%s\n", TAB($uqdn, 16),
			$ttl, $uqdn, $c_opt_domain);
		    if (exists($RRowners{$uqdn})) {
			$RRowners{$uqdn} .= "CNAME ";
		    } else {
			$RRowners{$uqdn} = " CNAME ";
		    }
		    $data = $uqdn;
		    while ($data ~~ /(?:\\[.]|[^.])*[.]/) {
			#
			# The UQDN consists of two or more labels.
			# Register the interior labels in the %RRowners hash
			# so that we can correctly distinguish between a
			# non-existent domain name and a domain name with no
			# DNS resource records during the auditing phase.
			#
			$data ~~ s/(?:\\[.]|[^.])*[.]//;  # strip leading label
			$RRowners{$data} = " " unless exists($RRowners{$data});
		    }
		    if ($show) {
			#
			# Register the CNAME in the %Spcl_CNAME hash
			# for later auditing.
			#
			$tmp = lc("$uqdn.$c_opt_domain");
			if (exists($Spcl_CNAME{$tmp})
			    && $Spcl_CNAME{$tmp} !~ /-c option/) {
			    $Spcl_CNAME{$tmp} .= ", -c option";
			} else {
			    $Spcl_CNAME{$tmp} = "-c option";
			}
		    }
		} elsif ($match ne " " && $Verbose) {
		    print STDERR "Line $line_num: Can't create CNAME ",
				 "for `$uqdn'; another RR exists.\n";
		    $show_host_line = 1;
		}
		if ($cmode ~~ /A/) {	    # also create CNAMEs for alias(es)
		    foreach $tmp (@aliases) {
			($alias = $tmp) ~~ s/[.]$netpat$//i;
			$make_rr = 1 unless $alias ~~ /^\*(?:$|[.])/;
			$error = CHECK_NAME($alias, 'CNAME');
			if ($error) {
			    $action = ($error == 3) ? "Skipping" : $DefAction;
			    if ($Verbose) {
				print STDERR "Line $line_num: $action; ",
					     "`$alias' not a valid hostname ",
					     "alias.\n";
				$show_host_line = 1;
			    }
			    $make_rr = 0 unless $action eq "Warning";
			}
			if ($make_rr) {
			    if (exists($RRowners{$alias})) {
				$match = $RRowners{$alias};
				1 while $match ~~ s/ (?:$DNSSEC_RRtypes) / /go;
			    } else {
				$match = " ";
			    }
			    if ($match eq " ") {
				PRINTF(*DOMAIN, "%s%s\tCNAME\t%s.%s\n",
				       TAB($alias, 16), $ttl, $uqdn,
				       $c_opt_domain);
				if (exists($RRowners{$alias})) {
				    $RRowners{$alias} .= "CNAME ";
				} else {
				    $RRowners{$alias} = " CNAME ";
				}
				$data = $alias;
				while ($data ~~ /(?:\\[.]|[^.])*[.]/) {
				    $data ~~ s/(?:\\[.]|[^.])*[.]//;
				    unless (exists($RRowners{$data})) {
					$RRowners{$data} = " ";
				    }
				}
			    } elsif ($Verbose) {
				print STDERR "Line $line_num: Can't create ",
					     "CNAME for `$alias'; another RR ",
					     "exists.\n";
				$show_host_line = 1;
			    }
			}
		    }
		}
	    } else {
		#
		# Defer creation of CNAMEs
		#
		if (exists($RRowners{$uqdn})) {
		    $match = $RRowners{$uqdn};
		    1 while $match ~~ s/ (?:$DNSSEC_RRtypes) / /go;
		} else {
		    $match = " ";
		}
		if ($match eq " " && $uqdn !~ /^\*(?:$|[.])/) {
		    unless (exists($c_Opt_Aliases{$uqdn})) {
			#
			# Register the deferred CNAME candidate.
			#
			$c_Opt_Aliases{$uqdn} = "$uqdn $netpat $ttl";
		    } else {
			#
			# A CNAME candidate is already registered for this
			# owner name.  Check whether the current `-c' option
			# was specified before the `-c' option that generated
			# the already-pending CNAME.
			#
			($tmp_uqdn, $tmp_netpat, $tmp) =
					      split(' ', $c_Opt_Aliases{$uqdn});
			if ($c_Opt_Spec{$netpat}{RANK} >
			    $c_Opt_Spec{$tmp_netpat}{RANK}) {
			    #
			    # The current `-c' option outranks the `-c' option
			    # that generated the already-registered CNAME
			    # candidate.  Override the registered candidate
			    # with the new CNAME.
			    #
			    $c_Opt_Aliases{$uqdn} = "$uqdn $netpat $ttl";
			    $tmp_cmode = $c_Opt_Spec{$tmp_netpat}{MODE};
			    $message = "A lower ranking -c option CNAME was "
				     . "replaced for `$uqdn'.\n";
			} else {
			    #
			    # If the current `-c' option is outranked, operate
			    # in a "first match wins" manner by not overwriting
			    # an already-registered CNAME candidate.
			    #
			    $tmp_cmode = $cmode;
			    $message = "A -c option CNAME is already pending "
				     . "for `$uqdn'.\n";
			}
			if (($tmp_cmode !~ /Q/ && $Verbose)
			    && ($uqdn ne $tmp_uqdn || $netpat ne $tmp_netpat)) {
			    #
			    # Report the conflict/override since the losing
			    # `-c' option's "quiet" flag is not in effect and
			    # this is not an occurrence of a multi-homed host.
			    #
			    $tmp_netpat ~~ s/\\//g;
			    $tmp = "$tmp_uqdn.$tmp_netpat";
			    print STDERR "Line $line_num: $message";
			    if ($uqdn eq $tmp_uqdn) {
				$message = "the hostname";
			    } else {
				$message = "an alias";
			    }
			    print STDERR "It was processed as $message ",
					 "of `$tmp'.\n";
			    $show_host_line = 1;
			}
		    }
		} elsif ($match ne " " && $cmode !~ /Q/ && $Verbose) {
		    print STDERR "Line $line_num: Can't create CNAME ",
				 "for `$uqdn'; another RR exists.\n";
		    $show_host_line = 1;
		}
		if ($cmode ~~ /A/) {
		    foreach $tmp (@aliases) {
			($alias = $tmp) ~~ s/[.]$netpat$//i;
			$make_rr = 1 unless $alias ~~ /^\*(?:$|[.])/;
			$error = CHECK_NAME($alias, 'CNAME');
			if ($error) {
			    $action = ($error == 3) ? "Skipping" : $DefAction;
			    if ($Verbose) {
				print STDERR "Line $line_num: $action; ",
					     "`$alias' not a valid hostname ",
					     "alias.\n";
				$show_host_line = 1;
			    }
			    $make_rr = 0 unless $action eq "Warning";
			}
			if ($make_rr) {
			    if (exists($RRowners{$alias})) {
				$match = $RRowners{$alias};
				1 while $match ~~ s/ (?:$DNSSEC_RRtypes) / /go;
			    } else {
				$match = " ";
			    }
			    if ($match eq " ") {
				unless (exists($c_Opt_Aliases{$alias})) {
				    $c_Opt_Aliases{$alias} = "$uqdn $netpat"
							   . " $ttl";
				} else {
				    ($tmp_uqdn, $tmp_netpat, $tmp) =
					     split(' ', $c_Opt_Aliases{$alias});
				    if ($c_Opt_Spec{$netpat}{RANK}
					> $c_Opt_Spec{$tmp_netpat}{RANK}) {
					$c_Opt_Aliases{$alias} = "$uqdn $netpat"
							       . " ttl";
					$tmp_cmode =
						 $c_Opt_Spec{$tmp_netpat}{MODE};
					$message = "A lower ranking -c option "
						 . "CNAME was replaced for "
						 . "`$alias'.\n";
				    } else {
					$tmp_cmode = $cmode;
					$message = "A -c option CNAME is "
						 . "already pending for "
						 . "`$alias'.\n";
				    }
				    if (($tmp_cmode !~ /Q/ && $Verbose)
					&& ($uqdn ne $tmp_uqdn
					    || $netpat ne $tmp_netpat)) {
					$tmp_netpat ~~ s/\\//g;
					$tmp = "$tmp_uqdn.$tmp_netpat";
					print STDERR "Line $line_num: ",
						     "$message";
					if ($alias eq $tmp_uqdn) {
					    $message = "the hostname";
					} else {
					    $message = "an alias";
					}
					print STDERR "It was processed as ",
						     "$message of `$tmp'.\n";
					$show_host_line = 1;
				    }
				}
			    } elsif ($cmode !~ /Q/ && $Verbose) {
				print STDERR "Line $line_num: Can't create ",
					     "CNAME for `$alias'; another RR ",
					     "exists.\n";
				$show_host_line = 1;
			    }
			}
		    }
		}
	    }
	    # Check if this was flagged as an intra-zone domain or
	    # if there is a matching -p argument.  A check made in
	    # PARSE_ARGS() has ensured that both conditions can not
	    # be simultaneously true.
	    #
	    if ($cmode ~~ /I/) {
		$match = 1;
	    } else {
		$match = 0;
		foreach $ptrpat (@p_Opt_Patterns) {
		    next if $names !~ /[.]$ptrpat(?:\s|$)/i;
		    $match = 1;
		    last;
		}
	    }
	    if ($match) {
		#
		# Exit from the -c processing loop and proceed to
		# the sections for processing the -p or -d options.
		#
		last;
	    } else {
		if ($show_host_line) {
		    print STDERR "> $_\n";
		    $show_host_line = 0;
		}
		next LINE;
	    }
	}

	# Check that the address is covered by a -n or -a option.
	# Search in the order of most specific network class to
	# the least specific network class, i.e.,
	#
	#   1. sub class-C (/25 to /32)
	#   2. class C     (/17 to /24)
	#   3. class B     (/9  to /16)
	#   3. class A     (/8)
	#
	$continue_search = 1;
	($data = $addr) ~~ s/[.]\d+$//;
	if (exists($Net_Ranges{"$data.X"})) {
	    $netpat = $Net_Ranges{"$data.X"};
	    #
	    # The "$netpat" variable contains a list of IP address ranges or
	    # individual IP addresses that correspond to one or more /25 to
	    # /32 networks having the /24 network in "$data" as the common
	    # class-C parent network.  Further searching is necessary to
	    # determine if there's a match with the last octet of current
	    # host entry's IP address.
	    #
	    $match = 0;
	    ($last_octet = $addr) ~~ s/^.+[.]//;
	    foreach $tmp (split(' ', $netpat)) {
		($first_ip, $last_ip) = split(/-/, $tmp);
		$last_ip = $first_ip unless defined($last_ip);
		if ($last_octet >= $first_ip && $last_octet <= $last_ip) {
		    $ptr_file = $Net_Ranges{"$data.$tmp"};
		    $match = 1;
		    last;
		}
	    }
	    $continue_search = 0 if $match || !$Supernetting_Enabled;
	}
	if ($continue_search) {
	    #
	    # When finding a match for a class C, B, or A network,
	    # the "$ptr_file" variable can either be the null string
	    # (signifying a -a option) or it can be a file descriptor
	    # typeglob having "*" as the first character (-n option).
	    #
	    if (exists($Net_Ranges{$data})) {
		#
		# A `-a/-n network/17-24' option was matched.
		#
		$ptr_file = $Net_Ranges{$data};
		$match = 1;
	    } else {
		#
		# Remove another octet to see if the address matches
		# a `-a/-n network/9-16' option, i.e., a class-B zone.
		#
		$data ~~ s/[.]\d+$//;
		if (exists($Net_Ranges{$data})) {
		    $ptr_file = $Net_Ranges{$data};
		    $match = 1;
		} else {
		    #
		    # Remove another octet to see if the address matches
		    # a `-a/-n network/8' option, i.e., a class-A zone.
		    #
		    $data ~~ s/[.]\d+$//;
		    if (exists($Net_Ranges{$data})) {
			$ptr_file = $Net_Ranges{$data};
			$match = 1;
		    } else {
			$match = 0;
		    }
		}
	    }
	}
	unless ($match) {
	    if ($Verbose) {
		print STDERR "Line $line_num: Skipping; IP not within ",
			     "range specified by -n/-a options.\n";
		if ($cmode ~~ /I/ && !$ignore_c_opt) {
		    print STDERR "Dangling CNAME(s) may exist in the -d ",
				 "domain due to prior -c option processing.\n";
		}
		print STDERR "> $_\n";
		$show_host_line = 0;
	    }
	    next LINE;
	}

	if ($ptr_file) {
	    #
	    # A -n option has been matched.  Separate the file handle for
	    # printing PTR zone data from the IP address template that is
	    # used for creating the relative owner name of the PTR record.
	    #
	    ($ptr_file, $ptr_template) = split(' ', $ptr_file, 2);
	}

	# Process -p options
	#
	# NOTE: The "@p_Opt_Patterns" array has been sorted by the FIXUP()
	#       subroutine so that the deepest subtrees of each domain will
	#       be matched before their ancestors in the domain tree.
	#
	foreach $netpat (@p_Opt_Patterns) {
	    next if $names !~ /(?:^|[.])$netpat(?:\s|$)/i;
	    next LINE if $addr eq $Localhost;
	    $pmode = $p_Opt_Mode_Spec{$netpat};
	    if ($pmode ~~ /O/) {
		#
		# The matched domain is a parent domain of the default
		# domain (-d option).  Make sure to override -p option
		# processing if the current host file entry also matches
		# the -d option domain.
		#
		last if $names ~~ /$Domain_Pattern(?:\s|$)/io;
	    }
	    if (!$ptr_file || $comment ~~ /\[\s*no(?:\s*-*\s*)?ptr\s*\]/i) {
		if ($show_host_line) {
		    print STDERR "> $_\n";
		    $show_host_line = 0;
		}
		next LINE;
	    }
	    #
	    # Accommodate differing host table formats unless this has
	    # already been done by a previously matched -c option.
	    #
	    if (!$reformatted_line && @aliases) {
		$p_opt_domain = $PTR_Pat_Rel{$netpat};
		if (lc("$canonical.$p_opt_domain") eq lc($aliases[0])) {
		    $canonical = $aliases[0];
		    shift(@aliases);
		}
		if (@aliases
		    && lc($canonical) eq lc("$aliases[0].$p_opt_domain")) {
		    shift(@aliases);
		}
	    }
	    unless ($canonical ~~ /(?:^|[.])$netpat$/i) {
		if ($show_host_line) {
		    print STDERR "> $_\n";
		    $show_host_line = 0;
		}
		next LINE;
	    }
	    #
	    # See the comments in the section for processing the -n option
	    # in PARSE_ARGS for an explanation on how the "/ee" modifier
	    # activates "$ptr_template" in the following substitution.
	    #
	    ($ptr_owner = $addr) ~~
			  s/(\d+)[.](\d+)[.](\d+)[.](\d+)/$ptr_template/ee;
	    $canonical .= "." unless $canonical ~~ /[.]$/;
	    #
	    # This program has a feature for choosing how PTR records
	    # get generated for multi-homed hosts.  They can either
	    # point to the multi-address canonical name (the default)
	    # or, alternatively, to the first unique single-address
	    # interface name.  The default method allows us to create
	    # the PTR record immediately while the alternate method
	    # requires us to defer the PTR creation since it may not
	    # yet be known whether the current host has more than one
	    # address.
	    #
	    # We'll first determine how to set the $default_ptr flag
	    # based on the relevant conditions and exceptions that
	    # may be present with this host.  Creation or deferment
	    # of the PTR record will then follow.
	    #
	    if (!@aliases || $pmode ~~ /A/) {
		#
		# No aliases or a "mode=A" argument in the -p option means
		# that there is no other choice but to use the canonical
		# name as the RDATA field of the PTR record.
		# NOTE: The "mode=A" argument overrides the `+m P' and `+m CP'
		#       options as well as the "[mh=p]" and "[mh=cp]" flags in
		#       the comment field of this host.
		#
		$default_ptr = 1;
	    } else {
		#
		# Test the status of any +m option that was specified
		# and whether or not it is being overridden by a "[mh=??]"
		# flag in the comment field.
		#
		unless ($Multi_Homed_Mode ~~ /P/) {
		    #
		    # Use the default PTR method unless overridden.
		    #
		    $default_ptr =
				 ($comment ~~ /\[\s*mh\s*=\s*(?:p|cp|pc)\s*\]/i)
				 ? 0 : 1;
		} else {
		    #
		    # Use the alternate PTR method unless overridden.
		    # NOTE: The absence of the "p" specification in the
		    #       comment flag signifies an override condition.
		    #
		    $default_ptr = ($comment ~~ /\[\s*mh\s*=\s*[cd]\s*\]/i)
				 ?? 1 !! 0;
		}
	    }
	    if ($default_ptr) {
		#
		# The PTR record must point to the canonical name
		# and thus can be created immediately.
		#
		unless (exists($p_opt_ptr{$addr})) {
		    unless ($ptr_file eq *DOMAIN) {
			PRINTF($ptr_file, "%s%s\tPTR\t%s\n", TAB($ptr_owner, 8),
			       $ttl, $canonical);
			$p_opt_ptr{$addr} = 1;
		    } elsif (exists($RRowners{$ptr_owner})
			     && $RRowners{$ptr_owner} ~~ / CNAME /) {
			if ($Verbose) {
			    print STDERR "Line $line_num: Can't create PTR ",
					 "for `$ptr_owner'; a CNAME RR ",
					 "exists.\n";
			    $show_host_line = 1;
			}
		    } else {
			PRINTF(*DOMAIN, "%s%s\tPTR\t%s\n", TAB($ptr_owner, 16),
			       $ttl, $canonical);
			$p_opt_ptr{$addr} = 1;
			if (exists($RRowners{$ptr_owner})) {
			    unless ($RRowners{$ptr_owner} ~~ / PTR /) {
				$RRowners{$ptr_owner} .= "PTR ";
			    }
			} else {
			    $RRowners{$ptr_owner} = " PTR ";
			}
			$data = $ptr_owner;
			while ($data ~~ /(?:\\[.]|[^.])*[.]/) {
			    $data ~~ s/(?:\\[.]|[^.])*[.]//;
			    unless (exists($RRowners{$data})) {
				$RRowners{$data} = " "
			    }
			}
		    }
		}
	    } else {
		#
		# Defer the creation of the PTR record until it can be
		# determined whether or not the canonical name is that
		# of a multi-homed host.  If so, the first non-common
		# alias will have an Address record in the forward-mapping
		# file and the PTR record will created to point to it
		# instead of the canonical name.
		#
		unless (exists($hosts_ptr{$canonical})) {
		    ($tmp = $netpat) ~~ s/\\[.]/./g;
		    $hosts_ptr{$canonical} = "$tmp ";
		}
		($addrpattern = $addr) ~~ s/[.]/\\./g;
		unless ($hosts_ptr{$canonical} ~~ /\b$addrpattern /) {
		    #
		    # Add the new IP address to the hash of canonical names
		    # for PTR records and store the deferred PTR data.
		    #
		    $hosts_ptr{$canonical} .= "$addr ";
		    $Deferred_PTR{"$canonical-$addr"} =
					     "$ptr_file $ptr_owner $ttl";
		}
		# Make sure that all aliases get indexed.
		#
		$aliases_ptr{"$canonical-$addr"} .= " @aliases ";
	    }
	    if ($show_host_line) {
		print STDERR "> $_\n";
		$show_host_line = 0;
	    }
	    next LINE;
	}

	# Accommodate differing host table formats unless this has
	# already been done by a previously matched intra-zone
	# -c option (mode=I).
	#
	if (!$reformatted_line && @aliases) {
	    if (lc("$canonical.$Domain") eq lc($aliases[0])) {
		$canonical = $aliases[0];
		shift(@aliases);
	    }
	    if (@aliases && lc($canonical) eq lc("$aliases[0].$Domain")) {
		shift(@aliases);
	    }
	}
	unless ($canonical ~~ /$Domain_Pattern$/io || $UseDefaultDomain) {
	    if ($Verbose && $ReportNonMatchingDomains) {
		print STDERR "Line $line_num: Skipping `$canonical'.\n",
			     "The canonical name does not match the -d ",
			     "option.\n",
			     "> $_\n";
		$show_host_line = 0;
	    }
	    next LINE;
	} else {
	    $canonical ~~ s/$Domain_Pattern$//io;  # strip off domain if present
	    if (exists($Hosts{$canonical})) {
		($addrpattern = $addr) ~~ s/[.]/\\./g;
		unless ($Hosts{$canonical} ~~ /\b$addrpattern /) {
		    #
		    # The above check prevents the creation of duplicate
		    # Address and PTR records.  Now go ahead and index the
		    # address by canonical name.
		    #
		    $Hosts{$canonical} .= "$addr ";
		    $addrpattern = "";
		}
	    } else {
		#
		# This is the first IP address for this host.
		#
		$Hosts{$canonical} = "$addr ";
		$addrpattern = "";
		$data = $canonical;
		while ($data ~~ /(?:\\[.]|[^.])*[.]/) {
		    $data ~~ s/(?:\\[.]|[^.])*[.]//;
		    $RRowners{$data} = " " unless exists($RRowners{$data});
		}
	    }
	    # Index aliases by name and address.
	    #
	    $Aliases{"$canonical-$addr"} .= " @aliases ";
	    $Comments{"$canonical-$addr"} .= $comment;
	    if ($ttl) {
		if (exists($owner_ttl{$canonical})) {
		    if (SECONDS($ttl) != SECONDS($owner_ttl{$canonical})) {
			if (SECONDS($ttl) < SECONDS($owner_ttl{$canonical})) {
			    $owner_ttl{$canonical} = $ttl;
			}
			if ($Verbose) {
			    print STDERR "Line $line_num: Hmm, a different ",
					 "TTL spec for `$canonical', using ",
					 "lowest value ",
					 "($owner_ttl{$canonical}).\n";
			    $show_host_line = 1;
			}
		    }
		} else {
		    $owner_ttl{$canonical} = $ttl;
		}
	    }
	    if ($ptr_file && $addrpattern eq "" && $addr ne $Localhost
		&& $comment !~ /\[\s*no(?:\s*-*\s*)?ptr\s*\]/i) {
		#
		# Construct the data for the PTR record.  See the comments
		# in the section for processing the -n option in PARSE_ARGS
		# for an explanation on how the "/ee" modifier activates
		# "$ptr_template" in the following substitution.
		#
		($ptr_owner = $addr) ~~
			      s/(\d+)[.](\d+)[.](\d+)[.](\d+)/$ptr_template/ee;
		unless (@aliases && $Do_CNAME) {
		    #
		    # No aliases or the -A option being in effect means
		    # that there is no other choice but to use the canonical
		    # name as the RDATA field of the PTR record.
		    # NOTE: The -A option overrides the `+m P' and `+m CP'
		    #       options as well as the "[mh=p]" and "[mh=cp]"
		    #       flags in the comment field of this host.
		    #
		    $default_ptr = 1;
		} else {
		    unless ($Multi_Homed_Mode ~~ /P/) {
			$default_ptr =
			   ($comment ~~ /\[\s*mh\s*=\s*(?:p|cp|pc)\s*\]/i)
				     ?? 0
				     !! 1;
		    } else {
			$default_ptr = ($comment ~~ /\[\s*mh\s*=\s*[cd]\s*\]/i)
				     ?? 1
				     !! 0;
		    }
		}
		if ($default_ptr) {
		    unless ($ptr_file eq *DOMAIN) {
			PRINTF($ptr_file, "%s%s\tPTR\t%s.%s.\n",
			       TAB($ptr_owner, 8), $ttl, $canonical, $Domain);
		    } elsif (exists($RRowners{$ptr_owner})
			     && $RRowners{$ptr_owner} ~~ / CNAME /) {
			if ($Verbose) {
			    print STDERR "Line $line_num: Can't create PTR ",
					 "for `$ptr_owner'; a CNAME RR ",
					 "exists.\n";
			    $show_host_line = 1;
			}
		    } else {
			PRINTF(*DOMAIN, "%s%s\tPTR\t%s\n",
			       TAB($ptr_owner, 16), $ttl, $canonical);
			if (exists($RRowners{$ptr_owner})) {
			    unless ($RRowners{$ptr_owner} ~~ / PTR /) {
				$RRowners{$ptr_owner} .= "PTR ";
			    }
			} else {
			    $RRowners{$ptr_owner} = " PTR ";
			}
			$data = $ptr_owner;
			while ($data ~~ /(?:\\[.]|[^.])*[.]/) {
			    $data ~~ s/(?:\\[.]|[^.])*[.]//;
			    unless (exists($RRowners{$data})) {
				$RRowners{$data} = " "
			    }
			}
		    }
		} else {
		    $Deferred_PTR{"$canonical-$addr"} = "$ptr_file $ptr_owner"
						      . " $ttl";
		}
	    }
	}
	if ($show_host_line) {
	    print STDERR "> $_\n";
	    $show_host_line = 0;
	}
    }
    close(*HOSTS);

    if ($Commentfile) {
	print STDOUT "Reading comments file `$Commentfile'...\n" if $Verbose;
	unless (OPEN(*F, '<', $Commentfile)) {
	    print STDERR "Unable to open the comments file': $!\n",
			 "Check your -C option argument.\n";
	    GIVE_UP();
	}
	$line_num = 0;
	while (<F>) {
	    $line_num++;
	    chop;
	    next if /^$/ || /^\s*#/;
	    ($key, $comment) = split(/:/, $_, 2);
	    if ($comment) {
		$Comment_RRs{$key} = $comment;
	    } elsif ($Verbose) {
		print STDERR "Line $line_num: Skipping; incorrectly ",
			     "formatted data.\n",
			     "> $_\n";
	    }
	}
	CLOSE(*F);
    }

    print STDOUT "Writing database files...\n" if $Verbose;

    # Go through the list of canonical names.
    # If there is more than one address associated with a name, it is a
    # multi-homed host.  Special checks are made for the generation of
    # A and/or CNAME RRs for multi-homed hosts in the CNAME() subroutine.
    #
    # Since the %Hosts hash may be quite large, do not call the keys()
    # function in a list context.  To do so would incur unnecessary
    # overhead in both time and memory space when every hash key is
    # slurped into the list at once.  Instead, the each() function will
    # be used to access the hash keys and elements one by one.
    # It's imperative, however, to first call keys() in a scalar context
    # in order to reset the internal hash iterator.  Otherwise, data might
    # be missed if the each() function doesn't start accessing the hash
    # from the beginning.
    #
    scalar(keys(%Hosts));
    while (($canonical, $data) = each %Hosts) {
	@addrs = split(' ', $data);

	$ttl = (defined($owner_ttl{$canonical})) ?? $owner_ttl{$canonical} !! "";
	foreach $addr (@addrs) {
	    #
	    # Print address record(s) for the canonical name.
	    #
	    if (exists($RRowners{$canonical})
		&& $RRowners{$canonical} ~~ / CNAME /) {
		if ($Verbose) {
		    print STDERR "Can't create A record for `$canonical' ",
				 "due to an existing CNAME RR.\n";
		}
	    } elsif ($addr ne $Localhost) {
		PRINTF(*DOMAIN, "%s%s\tA\t%s\n",
		       ($canonical eq $Owner_Field ?? "\t\t"
						   !! TAB($canonical, 16)),
		       $ttl, $addr);
		$Owner_Field = $canonical;
	    }
	}
	if ($Do_MX) {
	    MX($canonical, $ttl, @addrs);
	}
	if ($Commentfile || $Do_TXT) {
	    DO_COMMENTS_TXT($canonical, $ttl, @addrs);
	}
	if ($Do_RP) {
	    RP($canonical, $ttl, @addrs);
	}
	if ($Do_CNAME) {
	    CNAME($canonical, $ttl, @addrs);
	}
	if (exists($c_Opt_Aliases{$canonical})) {
	    #
	    # RRs for the default domain take precedence over identically-named
	    # CNAMEs requested by a -c option with "mode=D".
	    # Prevent the generation of an illegal duplicate DNS record by
	    # removing it from the deferred list.
	    #
	    ($tmp, $netpat, $tmp) = split(' ', $c_Opt_Aliases{$canonical}, 3);
	    $cmode = $c_Opt_Spec{$netpat}{MODE};
	    if ($Verbose && $cmode !~ /Q/) {
		print STDERR "Can't create CNAME for ",
			     "`$canonical.$c_Opt_Pat_Rel{$netpat}'; ",
			     "another RR exists.\n";
	    }
	    delete($c_Opt_Aliases{$canonical});
	}
    }

    if (keys(%c_Opt_Aliases)) {
	#
	# The deferred set of non-conflicting CNAMEs can finally be created.
	#
	while (($alias, $data) = each %c_Opt_Aliases) {
	    if (exists($RRowners{$alias})) {
		$match = $RRowners{$alias};
		1 while $match ~~ s/ (?:$DNSSEC_RRtypes) / /go;
	    } else {
		$match = " ";
	    }
	    ($canonical, $netpat, $ttl) = split(' ', $data, 3);
	    $cmode = $c_Opt_Spec{$netpat}{MODE};
	    $c_opt_domain = $c_Opt_Pat_Rel{$netpat};
	    if ($match eq " ") {
		$show = 0;
		if ($cmode !~ /I/) {
		    $show = $Show_Dangling_CNAMEs;
		    if (@Dangling_CNAME_Domains) {
			foreach $tmp (@Dangling_CNAME_Domains) {
			    next if $c_opt_domain !~ /^$tmp$/i;
			    $show = $Dangling_CNAME_Domains{$tmp};
			    last;
			}
		    }
		}
		if ($c_opt_domain ~~ /$Domain_Pattern$/io) {
		    $c_opt_domain ~~ s/$Domain_Pattern$//io;
		} else {
		    $c_opt_domain .= ".";
		}
		PRINTF(*DOMAIN, "%s%s\tCNAME\t%s.%s\n", TAB($alias, 16),
		       $ttl, $canonical, $c_opt_domain);
		if (exists($RRowners{$alias})) {
		    $RRowners{$alias} .= "CNAME ";
		} else {
		    $RRowners{$alias} = " CNAME ";
		}
		$tmp = $alias;
		while ($tmp ~~ /(?:\\[.]|[^.])*[.]/) {
		    $tmp ~~ s/(?:\\[.]|[^.])*[.]//;
		    $RRowners{$tmp} = " " unless exists($RRowners{$tmp});
		}
		if ($show) {
		    $tmp = lc("$canonical.$c_opt_domain");
		    if (exists($Spcl_CNAME{$tmp})
			&& $Spcl_CNAME{$tmp} !~ /-c option/) {
			$Spcl_CNAME{$tmp} .= ", -c option";
		    } else {
			$Spcl_CNAME{$tmp} = "-c option";
		    }
		}
	    } elsif ($Verbose && $cmode !~ /Q/) {
		print STDERR "Can't create CNAME for ",
			     "`$canonical.$c_Opt_Pat_Rel{$netpat}'; ",
			     "another RR exists.\n";
	    }
	}
    }

    if (keys(%Deferred_PTR) || keys(%Pending_PTR)) {
	#
	# Make sure that deferred PTR records are output.
	#
	if (keys(%hosts_ptr)) {
	    #
	    # Look for domain names that matched a -p option which also
	    # point to multi-homed hosts.  The methodology is basically
	    # the same as in the CNAME subroutine.
	    #
	    while (($canonical, $data) = each %hosts_ptr) {
		($p_opt_domain, @addrs) = split(' ', $data);
		if (@addrs > 1) {
		    #
		    # Found a multi-homed host.
		    #
		    foreach $addr (@addrs) {
			@aliases = split(' ', $aliases_ptr{"$canonical-$addr"});
			foreach $alias (@aliases) {
			    #
			    # For every IP address, check each alias for the
			    # following:
			    #
			    #   1. Skip aliases that are identical to the FQDN.
			    #   2. Skip aliases that are common to all addresses
			    #      since they have CNAMEs assigned to them.
			    #   3. Make the necessary fix-ups so that the PTR
			    #      record will point to the first non-common
			    #      alias since it's this alias that will have an
			    #      Address RR in the forward-mapping data file.
			    #   4. Do nothing if we run out of aliases.  The
			    #      default PTR record which points to the
			    #      canonical name will be generated in the
			    #      subsequent block.
			    #
			    next if $canonical eq "$alias.$p_opt_domain."
				    || $canonical eq "$alias.";
			    $common_alias = 1;
			    foreach $tmp (@addrs) {
				unless ($aliases_ptr{"$canonical-$tmp"} ~~
								   / $alias /) {
				    $common_alias = 0;
				    last;
				}
				last unless $common_alias;
			    }
			    if ($common_alias) {
				#
				# Remove the alias from this as well as the
				# other addresses of this host so that it
				# won't be encountered again.
				#
				foreach $tmp (@addrs) {
				    $aliases_ptr{"$canonical-$tmp"} ~~
								  s/ $alias / /;
				}
			    } elsif (exists $Deferred_PTR{"$canonical-$addr"}) {
				#
				# Make the necessary updates so that
				# reverse-mapping queries are answered
				# with the unique interface name instead
				# of the multi-address canonical name.
				#
				($ptr_file, $ptr_owner, $ttl) =
				   split(' ', $Deferred_PTR{"$canonical-$addr"},
					  3);
				$tmp = $alias;
				unless ($alias ~~ /[.]$/) {
				    $tmp .= ".$p_opt_domain.";
				}
				$Pending_PTR{$ptr_file}{$ptr_owner} =
								    "$tmp $ttl";
				delete($Deferred_PTR{"$canonical-$addr"});
				last;		# finished with this IP address
			    }
			}
		    }
		}
	    }
	    scalar(keys(%Deferred_PTR));    # Reset hash iterator before leaving
	}
	while (($canonical, $data) = each %Deferred_PTR) {
	    #
	    # Anything left over in the deferred PTR hash gets the default
	    # treatment - a PTR record that points to the canonical name.
	    #
	    $canonical ~~ s/-(?:\d+[.]){3}\d+$//;
	    ($ptr_file, $ptr_owner, $ttl) = split(' ', $data, 3);
	    $Pending_PTR{$ptr_file}{$ptr_owner} = "$canonical $ttl";
	}
	scalar(keys(%Pending_PTR));
	while (($ptr_file, $addr) = each %Pending_PTR) {
	    foreach $ptr_owner (sort { $a cmp $b }
				keys %{ $Pending_PTR{$ptr_file} }) {
		($canonical, $ttl) =
			     split(' ', $Pending_PTR{$ptr_file}{$ptr_owner}, 2);
		unless ($ptr_file eq *DOMAIN) {
		    $canonical .= ".$Domain." unless $canonical ~~ /[.]$/;
		    PRINTF($ptr_file, "%s%s\tPTR\t%s\n", TAB($ptr_owner, 8),
			   $ttl, $canonical);
		} elsif (exists($RRowners{$ptr_owner})
			 && $RRowners{$ptr_owner} ~~ / CNAME /) {
		    if ($Verbose) {
			print STDERR "Can't create PTR record for ",
				     "`$ptr_owner' due to an existing ",
				     "CNAME RR.\n";
		    }
		} else {
		    PRINTF(*DOMAIN, "%s%s\tPTR\t%s\n", TAB($ptr_owner, 16),
			   $ttl, $canonical);
		    if (exists($RRowners{$ptr_owner})) {
			unless ($RRowners{$ptr_owner} ~~ / PTR /) {
			    $RRowners{$ptr_owner} .= "PTR ";
			}
		    } else {
			$RRowners{$ptr_owner} = " PTR ";
		    }
		    $data = $ptr_owner;
		    while ($data ~~ /(?:\\[.]|[^.])*[.]/) {
			$data ~~ s/(?:\\[.]|[^.])*[.]//;
			$RRowners{$data} = " " unless exists($RRowners{$data});
		    }
		}
	    }
	}
    }

    # Deal with 'spcl' files.
    #
    if (-r "$Search_Dir/$Special_File") {
	PRINTF(*DOMAIN, "\n\$INCLUDE $DB_Dir/%s\n", $Special_File);
	if ($Verbose) {
	    print STDOUT "File `$Search_Display_Dir/$Special_File' included.\n";
	}
    }
    # Use the Schwartzian Transform (documented in "Programming Perl",
    # 3rd Edition, O'Reilly & Associates) to do up to a five-key sort
    # of each possible octet and ending range of the IP subnet keys
    # in the "%Net_Zones" hash.  This is done to display "spcl" files
    # in network-numerical order as they are found.
    # NOTE: Since the existing "N" octets of a supernet compare equally
    #	   to the corresponding first "N" octets of its constituent
    #	   subnet(s), make sure to return -1 or 1 after the last octet
    #	   of the supernet is encountered.  Otherwise, run-time warnings
    #	   about the comparison of an uninitialized value will be output.
    #
    @sorted_nets = ();
    @sorted_nets = map { $_->[0] }
		   sort {
			  $a_len = $#$a;
			  $b_len = $#$b;
			  @a_fields = @$a[1..$a_len];
			  @b_fields = @$b[1..$b_len];

			  $a_fields[0] <=> $b_fields[0]	# Sort 1st octet.
			  ||				# If equal and
			  (($a_len == 1 && $b_len > 1) ?? -1 !! 0)
			  ||
			  (($a_len > 1 && $b_len == 1) ??  1 !! 0)
			  ||				# both have 2nd octet,
			  $a_fields[1] <=> $b_fields[1]	# sort 2nd octet.
			  ||				# If equal and
			  (($a_len == 2 && $b_len > 2) ?? -1 !! 0)
			  ||
			  (($a_len > 2 && $b_len == 2) ??  1 !! 0)
			  ||				# both have 3rd octet,
			  $a_fields[2] <=> $b_fields[2]	# sort 3rd octet.
			  ||				# If equal and
			  (($a_len == 3 && $b_len > 3) ?? -1 !! 0)
			  ||
			  (($a_len > 3 && $b_len == 3) ??  1 !! 0)
			  ||				# both have 4th octet,
			  $a_fields[3] <=> $b_fields[3]	# sort 4th octet.
			  ||				# If equal and
			  (($a_len == 4 && $b_len > 4) ?? -1 !! 0)
			  ||
			  (($a_len > 4 && $b_len == 4) ??  1 !! 0)
			  ||				# both have 5th element,
			  $a_fields[4] <=> $b_fields[4]	# sort sub-ClassC range.
		   }
		   map { [$_, split /[.]|-/] } (keys(%Net_Zones));

    foreach $key (@sorted_nets) {
	$data = $Net_Zones{$key};
	($zone_name, $spcl_file) = split(' ', $data, 2);
	if (-r "$Search_Dir/$spcl_file") {
	    $data = $Net_Ranges{$key};
	    ($ptr_file, $ptr_template) = split(' ', $data, 2);
	    PRINTF($ptr_file, "\n\$INCLUDE $DB_Dir/%s\n", $spcl_file);
	    if ($Verbose) {
		print STDOUT "File `$Search_Display_Dir/$spcl_file' ",
			     "found and included.\n";
	    }
	    #
	    # Make sure to disable checking of single-character hostnames
	    # and aliases since this RFC-952 restriction is limited to
	    # entries in the host table.
	    #
	    $tmp_rfc_952 = $RFC_952;
	    $RFC_952 = 0;

	    # Since all forward-mapping data has now been accounted for,
	    # the "READ_RRs" subroutine will be able to issue a warning
	    # if it detects a PTR record which points to an in-zone CNAME.
	    #
	    $zone_name .= ".";
	    $Newline_Printed = READ_RRs("$Search_Dir/$spcl_file", $zone_name,
					$zone_name, $zone_name, 0);
	    if ($Verbose) {
		print STDERR "\n" while $Newline_Printed--;
	    } else {
		$Newline_Printed = 0;
	    }
	    $RFC_952 = $tmp_rfc_952;
	}
    }
    if ($Open_DB_Files) {
	#
	# Close any DB files that may still be open since we are finished
	# with the task of writing resource records to them.
	#
	scalar(keys(%LRUtable));
	while (($key, $data) = each %LRUtable) {
	    CLOSE($key) if $data;
	}
    }
    return;
}




#
# Subroutine to check for bad names
# No check is made for maximum length of hostnames and/or domain labels.
#
# Return values:
#   0 = valid name within the selected checking context
#   1 (not returned - reserved)
#   2 = invalid name which violates RFC-1123 and/or RFC-952
#   3 = invalid DNS name within all checking contexts
#
sub CHECK_NAME {
    my ($name, $rrtype) = @_;
    my $bad_chars;

    # Regular Expression processing can get expensive in terms
    # of execution time.  Since this subroutine can be called
    # literally thousands of times during a program run, it is
    # imperative that duplicate pattern processing is eliminated.

    if ($RFC_1123 && $rrtype ~~ /^(?:A|MX|WKS)$/) {
	#
	# The name checking that is done in this block is a
	# superset of what is done for other other record types
	# or when RFC-1123 checking is not in effect.  Therefore,
	# we will be able to exit with a definitive result.
	#
	# At this point, RFC-1123 name checking is in effect for
	# canonical hostnames in the host table as well as DNS
	# domain names with the following record types: A, MX, or WKS.
	#
	# The character set of such names is limited to digits,
	# the minus sign (-), the period (.), and any mix of
	# upper/lowercase letters.  Hostnames and domain label
	# names must not begin or end with a minus sign or period.
	# The RFC-952 prohibition against names beginning with
	# numbers is lifted and hostnames can now have a maximum
	# length of 255 characters.
	#
	# The RDATA fields of certain other record types also
	# qualify for more stringent name checking according to
	# the following table:
	#
	#         RRtype    owner field    RDATA field
	#	  ------    -----------    -----------
	#           A          yes             n/a
	#           MX         yes             yes (exchange-dname portion)
	#          WKS         yes             n/a
	#           NS         no              yes
	#           RP         no	       yes (mbox-dname portion)
	#          SOA         no              yes (MNAME and RNAME)
	#          PTR         no              yes
	#          SRV         no              yes
	#          NSAP        no              n/a
	#         AFSDB        no              yes (hostname portion)
	#           RT         no              yes (intermediate-host portion)
	#
	# These RDATA fields make it to this point in the subroutine
	# by calling CHECK_NAME with a record type of "A".
	# NOTE: Since absolute domain names, i.e., those terminated
	#       with the "." (root zone) character, are not allowed
	#       in host files, such absolute names are detected in
	#       this processing block and flagged as errors.
	#       In the context of a zone file, however, absolute
	#       domain names are required.  When called from an
	#       an absolute domain name context dealing with A,
	#       MX, or WKS records, make sure to remove any
	#       terminating "." character before calling CHECK_NAME().
	#
	if ($name ~~ /^[.-]|[.-]$|[.][.]|[.]-|-[.]/) {
	    #
	    # This hostname/domain name is bad but we now need
	    # to know how bad.  If it merely violates RFC-1123
	    # and we're processing a host table, it's possible
	    # to let the user off with a warning depending on
	    # what `-I' option is in effect.
	    # A violation of the basic DNS naming rules, however,
	    # means the name has no hope of being loaded by a
	    # BIND name server.  In this case, we must set the
	    # return code to a special value so that the hostname
	    # can be skipped if we're processing a host table.
	    #
	    $name ~~ s/-//g;
	    return 3 if $name ~~ /^[.]|[.][.]$/;
	    return 2;
	}
	$bad_chars = $name;
	$bad_chars ~~ tr/A-Za-z0-9.-//d;
	return 2 if $bad_chars;
	return 2 if $RFC_952 && $rrtype eq "A" && length($name) == 1;
	return 0;
    }

    # Regardless of the state of the "$RFC_1123" flag, this section
    # of the subroutine is limited to checking for the basic validity
    # of a DNS domain name.

    # Domain names must not begin with an unescaped
    # dot nor contain adjacent unescaped dots.
    #
    if ($name ~~ /^[.]|[^\\][.][.]/) {
	#
	# No matter what level of name checking is in effect,
	# we've encountered a basic DNS name error that will
	# prevent a zone from being loaded by a BIND name server.
	# If the host table is being processed, unilaterally
	# declare that the entry is being skipped by setting
	# a special return value.
	#
	return 3;
    }
    return 2 if $RFC_952 && $rrtype eq "CNAME" && length($name) == 1;
    return 0;
}


#
# Subroutine to fit a name into a tab-delimited space
#
sub TAB {
    my ($name, $field) = @_;
    my $tabs;

    $tabs = $field - length($name);
    return "$name " if $tabs <= 0;
    while ($tabs > 0) {
	$name .= "\t";
	$tabs -= 8;
    }
    return $name;
}


#
# Subroutine to print to a DB file and utilize a data structure
# to accommodate limits on the number of concurrently-open files.
# NOTE: Do not use this subroutine to write to non-DB (zone data)
#       files unless their filenames and filehandles have been
#       registered in the %DB_Filehandle and %LRUtable hashes.
#
# As a host file is processed, the appropriate reverse-mapping
# DB files are opened as the IP addresses are encountered.
# Since there's no requirement that a host file be sorted in
# numerical IP address order, there's nothing in the input data
# stream that can signal us when a file can be closed.  So we
# just keep opening files.
#
# Depending on the size of the host file, we may eventually
# reach the limit of concurrently-open files imposed by either
# the computer's operating system or the -L option of `h2n'.
# A file must be closed in order to free up the resources for
# the new file to be opened.  Ideally, we should choose the
# Least Recently Used (LRU) file for closure.
#
# This subroutine will maintain the %LRUtable hash to identify
# the LRU files.  Each time a record is written to a DB file,
# the "$Print_Sequence" number is incremented and assigned as
# the value of the corresponding filehandle key in %LRUtable.
# When the OPEN() subroutine needs to close a file, it will
# sort %LRUtable and close the file with the smallest, i.e.,
# oldest, print sequence number.
#
sub PRINTF {
    (local *FILE, my @args) = @_;
    my $output_file;

    unless ($LRUtable{*FILE}) {
	#
	# The DB file is closed - re-open it in append mode.
	#
	$output_file = "$DB_Filehandle{*FILE}";
	unless (OPEN(*FILE, '>>', $output_file)) {
	    print STDERR "Couldn't re-open `$output_file' in PRINTF().\n",
			 "Error: $!\n";
	    GIVE_UP();
	}
    }
    if (printf FILE @args) {
	$LRUtable{*FILE} = ++$Print_Sequence;
    } else {
	$output_file = "$DB_Filehandle{*FILE}";
	print STDERR "Couldn't write to `$output_file' in PRINTF().\n",
		     "Error: $!\n";
	GIVE_UP();
    }
    return;
}


#
# Subroutine to open a file.  If necessary, a currently-open
# file will be closed if all available filehandles are in use.
# NOTE: Unlike the PRINTF() subroutine above, the OPEN() and
#       CLOSE() subroutines may be called to service non-DB
#       files.  Currently-open DB files will be closed as
#       necessary to open a non-DB file.
#       An example of where this is used is in READ_RRs().
#       The LRU service of OPEN() is not really needed to
#       process a forward-mapping `spcl' file since this is
#       done before the host file is read.  However, READ_RRs()
#       is also called after the host file is read if any
#       reverse-mapping `spcl' files are discovered.
#       Here, the LRU service of OPEN() is needed because of
#       the large number of DB files that may be open as a
#       result of processing the host file.
#
sub OPEN {
    (local *FILE_HANDLE, my $mode, my $arg) = @_;
    my ($ok, $tries, @sorted_fh);

    if ($Open_DB_Files < $Open_File_Limit) {
	$ok = open(*FILE_HANDLE, $mode, $arg);
    }
    unless ($ok) {
	#
	# Assume that we have exceeded "$Open_File_Limit (-L option)
	# or we've run into a limit set by the operating system.
	# Either way, we'll sort %LRUtable to find the least recently
	# used file that's still open and close it to make room for
	# the new file that needs to be opened.
	#
	@sorted_fh = sort { $LRUtable{$a} <=> $LRUtable{$b}; } keys %LRUtable;
	$tries = 0;
	foreach my $fh (@sorted_fh) {
	    next if $LRUtable{$fh} == 0;
	    CLOSE($fh);		# CLOSE() decrements "$Open_DB_Files"
	    $tries++;		# and sets $LRUtable{$fh} to zero
	    $ok = open(*FILE_HANDLE, $mode, $arg);
	    #
	    # It's reasonable to assume that a single CLOSE() will be
	    # sufficient for the new OPEN() to succeed.  Be flexible,
	    # however, and allow three tries.  Bail out if the OPEN()
	    # still fails since the operating system may be complaining
	    # about a problem that's unrelated to concurrently-open files.
	    #
	    last if $ok || $tries >= 3;
	}
    }
    if ($ok) {
	$Open_DB_Files++ if exists($DB_Filehandle{*FILE_HANDLE});
	return $ok;
    } else {
	return;		# return the undefined value just like the real open()
    }
}


#
# Subroutine to close a file and maintain the %DB_Filehandle
# data structure for managing DB files.
#
sub CLOSE {
    (local *FHANDLE) = @_;
    my $ok;

    $ok = close(*FHANDLE);
    if ($ok && exists($DB_Filehandle{*FHANDLE})) {
	$Open_DB_Files-- if $Open_DB_Files > 0;
	$LRUtable{*FHANDLE} = 0;
    }
    return;
}


#
# Generate resource record data for text strings from the comment
# field that are found as keys in the comment file (-C) and/or
# generate TXT records from left-over comment text after any
# -C keys and special processing flags have been filtered.
#
sub DO_COMMENTS_TXT {
    my ($canonical, $ttl, @addrs) = @_;
    my ($addr, $class, $comments, $rrtype, $skip_C_opt, $skip_t_opt, $status);
    my ($tmp, $tmp_load_status, $tmp_verbose, $token);
    my (@rr_buffer);

    $skip_C_opt = $skip_t_opt = 0;
    $comments = "";
    foreach $addr (@addrs) {
	$comments .= " " . $Comments{"$canonical-$addr"};
    }
    for ($comments) {
	#
	# Remove all special processing flags except "[no -C]" and "[no -t]"
	#
	s/\[\s*no(?:\s*-*\s*)?smtp\s*\]//gi;
	s/\[\s*smtp(?:(?:\s*-*\s*)?only)?\s*\]//gi;
	s/\[\s*(?:no(?:\s*-*\s*)?)?mx\s*\]//gi;
	s/\[\s*rafcp\s*\]//gi;
	s/\[\s*ttl\s*=\s*(?:\d+|(?:\d+[wdhms])+)\s*\]//gi;
	s/\[\s*rp\s*=\s*(?:[^\s"]+)?[^"]*(?:"[^"]*")?[^\]]*\]//gi;
	s/\[\s*mh\s*=\s*(?:d|c|p|cp|pc)\s*\]//gi;
	s/\[\s*no(?:\s*-*\s*)?ptr\s*\]//gi;
	s/\[\s*(?:no|skip|ignore)\s*-(?-i)c\s*\]//gi;# match only "-c", not "-C"
    }
    if ($comments ~~ /\[\s*(?:no|skip|ignore)\s*-(?-i)C\s*\]/i) {
	$skip_C_opt = 1;
	$comments ~~ s/\[\s*(?:no|skip|ignore)\s*-(?-i)C\s*\]//gi;
    }
    if ($comments ~~ /\[\s*(?:no|skip|ignore)\s*-(?-i)t\s*\]/i) {
	$skip_t_opt = 1;
	$comments ~~ s/\[\s*(?:no|skip|ignore)\s*-(?-i)t\s*\]//gi;
    }

    if ($Commentfile && $comments) {
	foreach $token (split(' ', $comments)) {
	    next unless exists($Comment_RRs{$token});
	    if ($Do_TXT && !$skip_t_opt) {
		#
		# Remove the -C token from the comment so that
		# it does not create or appear in a TXT record.
		#
		$comments ~~ s/\s$token(?:\s|$)/ /;
	    }
	    next if $skip_C_opt;
	    ($class, $rrtype, $tmp) = split(' ', $Comment_RRs{$token}, 3);
	    unless ($class ~~ /^(?:IN|CH|HS)$/) {
		#
		# Assume the optional CLASS field was omitted (defaults
		# to IN) and that "$class" has the parsed RR type.
		#
		$rrtype = $class
	    }
	    $rrtype = uc($rrtype);
	    if (exists($RRowners{$canonical})
		&& $RRowners{$canonical} ~~ / CNAME /) {
		if ($Verbose) {
		    print STDERR "Can't create $rrtype record for ",
				 "`$canonical' due to an existing CNAME RR.\n";
		}
	    } else {
		#
		# First submit the candidate resource record to READ_RRs()
		# to check its basic syntax.  If everything is fine, the
		# record will be registered in the %RRowners hash.
		#
		@rr_buffer = ();
		push(@rr_buffer, "-C option");
		push(@rr_buffer, sprintf("%s%s\t%s\n", TAB($canonical, 16),
					 $ttl, $Comment_RRs{$token}));
		$tmp_load_status = $Load_Status;
		$tmp_verbose = $Verbose;
		$Verbose = 1;
		$status = READ_RRs(\@rr_buffer, "$Domain.", "$Domain.",
				   "$Domain.", 0);
		$Verbose = $tmp_verbose;
		$status = $Load_Status if $Load_Status > $status;
		unless ($status) {
		    PRINTF(*DOMAIN, "%s%s\t%s\n",
			   ($canonical eq $Owner_Field ?? "\t\t"
						       !! TAB($canonical, 16)),
			   $ttl, $Comment_RRs{$token});
		    $Owner_Field = $canonical;
		} elsif ($tmp_load_status < $Load_Status) {
		    #
		    # Since the the bad resource record was not written
		    # to the DB file, make sure to reset the "$Load_Status"
		    # flag back to its previous value to prevent any false
		    # alarm messages about the DB file being having bad
		    # data after `h2n' completes processing.
		    #
		    $Load_Status = $tmp_load_status;
		}
	    }
	}
    }

    if ($Do_TXT && !$skip_t_opt) {
	$comments ~~ s/^\s+//;
	$comments ~~ s/\s+$//;
	if ($comments && ($Quoted_Txt_Only || $Quoted_Txt_Preferred)) {
	    if ($comments ~~ /["]/) {
		#
		# Remove unquoted text from the comment
		# field before generating the TXT record.
		#
		$comments ~~ s/^[^"]+//;
		$comments ~~ s/[^"]+$//;
	    } elsif ($Quoted_Txt_Only) {
		#
		# No quoted text means that no TXT record should be written.
		#
		$comments = "";
	    }
	}
	if ($comments) {
	    if (exists($RRowners{$canonical})
		&& $RRowners{$canonical} ~~ / CNAME /) {
		if ($Verbose) {
		    print STDERR "Can't create TXT record for `$canonical' ",
				 "due to an existing CNAME RR.\n";
		}
	    } else {
		#
		# Per RFC-1035, text with no whitespace does not have to be
		# enclosed with double-quote characters.  Double-quotes that
		# are part of the text string must be escaped.  Naturally,
		# unescaped quotes must be balanced.
		#
		# The BIND name server will quote each token of an unquoted
		# text string having whitespace, e.g.,
		#
		#   db.file
		#   -------
		#   host   TXT  This is not a \"quoted\" string.
		#
		#   BIND presentation format
		#   ------------------------
		#   host   TXT  "This" "is" "not" "a" "\"quoted\"" "string."
		#
		# After first submitting the candidate TXT record to READ_RRs(),
		# if the comment string does not contain any double quotes,
		# we will add the surrounding quotes before writing the TXT RR.
		# If the comment string already does contain double-quotes,
		# the TXT RR will be written as-is with no added quotes.
		#
		@rr_buffer = ();
		push(@rr_buffer, "-t option");
		push(@rr_buffer, sprintf("%s%s\tTXT\t%s\n",
					 TAB($canonical, 16), $ttl, $comments));
		$tmp_load_status = $Load_Status;
		$tmp_verbose = $Verbose;
		$Verbose = 1;
		$status = READ_RRs(\@rr_buffer, "$Domain.", "$Domain.",
				   "$Domain.", 0);
		$Verbose = $tmp_verbose;
		$status = $Load_Status if $Load_Status > $status;
		unless ($status) {
		    unless ($comments ~~ /["]/) {
			$comments = '"' . $comments . '"';
		    }
		    PRINTF(*DOMAIN, "%s%s\tTXT\t%s\n",
			   ($canonical eq $Owner_Field ?? "\t\t"
						       !! TAB($canonical, 16)),
			   $ttl, $comments);
		    $Owner_Field = $canonical;
		} elsif ($tmp_load_status < $Load_Status) {
		    $Load_Status = $tmp_load_status;
		}
	    }
	}
    }
    return;
}


#
# Generate MX record data
#
sub MX {
    my ($canonical, $ttl, @addrs) = @_;
    my ($addr, $comments, $global, $localhost, $rafcp, $rdata, $self);

    $localhost = 0;
    foreach $addr (@addrs) {
	$comments .= " " . $Comments{"$canonical-$addr"};
	$localhost = 1 if $addr eq $Localhost;
    }

    # As of version 2.45, the "[smtp]" flag by itself is sufficient
    # to suppress the global MX records (-m option) and leave only
    # the self-pointing MX record.  The "[smtp] [no mx]" combination
    # no longer has to be specified.  Existing host file entries that
    # have "[smtp] [no mx]" will continue to work as before.
    #
    # As of version 2.61, an enhancement to the -M option permits MX
    # records to be generated on an exception basis, i.e., no MX
    # records will be generated unless one or more of the MX-related
    # flags are present.  Version 2.61 also introduced a new flag,
    # "[mx]", which, by itself, specifies that the self-pointing
    # and global MX records (-m option) should be created for the host.
    #
    $self = $global = $rafcp = 0;
    unless ($comments ~~ /\[[^]]*(?:mx|smtp)[^]]*\]/i) {
	#
	# The default MX-related flag is "[mx]" unless overridden
	# by specifying one of the other flags in the -M option.
	#
	$comments = $Do_MX . $comments;
    }
    $self = $global = 1 if $comments ~~ /\[\s*mx\s*\]/i;
    $self = $global = 0 if $comments ~~ /\[\s*no(?:\s*-*\s*)?mx\s*\]/i;
    if ($comments ~~ /\[\s*no(?:\s*-*\s*)?smtp\s*\]/i) {
	$self = 0;
	$global = 1;
    }
    if ($comments ~~ /\[\s*smtp(?:(\s*-*\s*)?only)?\s*\]/i) {
	$self = 1;
	$global = 0;
    }
    if ($comments ~~ /\[\s*rafcp\s*\]/i) {
	$rafcp = 1;
	$self = $global = 0;
    }

    if (exists($RRowners{$canonical}) && $RRowners{$canonical} ~~ / CNAME /) {
	if (($rafcp || $Do_WKS) && $Verbose) {
	    print STDERR "Can't create WKS record for `$canonical' ",
			 "due to an existing CNAME RR.\n";
	}
	if (($self || $global) && $Verbose) {
	    print STDERR "Can't create MX record for `$canonical' ",
			 "due to an existing CNAME RR.\n";
	}
	return;
    }
    # If `[rafcp]' is specified in the comment section, add in a WKS record,
    # and do not add any MX records.
    #
    if ($rafcp) {
	foreach $addr (@addrs) {
	    PRINTF(*DOMAIN, "%s%s\tWKS\t%s rafcp\n",
		   ($canonical eq $Owner_Field ?? "\t\t" !! TAB($canonical, 16)),
		   $ttl, $addr);
	    $Owner_Field = $canonical;
	}
	if (exists($RRowners{$canonical})) {
	    unless ($RRowners{$canonical} ~~ / WKS /) {
		$RRowners{$canonical} .= "WKS ";
	    }
	} else {
	    $RRowners{$canonical} = " WKS ";
	}
    } elsif (!$localhost) {
	if ($self) {
	    # Add WKS if requested
	    if ($Do_WKS) {
		foreach $addr (@addrs) {
		    PRINTF(*DOMAIN, "%s%s\tWKS\t%s tcp smtp\n",
			   ($canonical eq $Owner_Field ?? "\t\t"
						       !! TAB($canonical, 16)),
			   $ttl, $addr);
		    $Owner_Field = $canonical;
		}
		if (exists($RRowners{$canonical})) {
		    unless ($RRowners{$canonical} ~~ / WKS /) {
			$RRowners{$canonical} .= "WKS ";
		    }
		} else {
		    $RRowners{$canonical} = " WKS ";
		}
	    }
	    PRINTF(*DOMAIN, "%s%s\tMX\t%s %s\n",
		   ($canonical eq $Owner_Field ?? "\t\t" !! TAB($canonical, 16)),
		   $ttl, $DefMXWeight, $canonical);
	    $Owner_Field = $canonical;
	    if (exists($RRowners{$canonical})) {
		unless ($RRowners{$canonical} ~~ / MX /) {
		    $RRowners{$canonical} .= "MX ";
		}
	    } else {
		$RRowners{$canonical} = " MX ";
	    }
	}
	if (@MX > 0 && $global) {
	    foreach $rdata (@MX) {
		PRINTF(*DOMAIN, "%s%s\tMX\t%s\n",
		       ($canonical eq $Owner_Field ?? "\t\t"
						   !! TAB($canonical, 16)),
		       $ttl, $rdata);
		$Owner_Field = $canonical;
	    }
	    if (exists($RRowners{$canonical})) {
		unless ($RRowners{$canonical} ~~ / MX /) {
		    $RRowners{$canonical} .= "MX ";
		}
	    } else {
		$RRowners{$canonical} = " MX ";
	    }
	}
    }
    return;
}


#
# Generate RP record data
#
sub RP {
    my ($canonical, $ttl, @addrs) = @_;
    my ($addr, $comments, $domain_part, $rp, $rp_txt, $user_part);

    if (exists($RRowners{$canonical}) && $RRowners{$canonical} ~~ / CNAME /) {
	if ($Verbose) {
	    print STDERR "Can't create RP record for `$canonical' ",
			 "due to an existing CNAME RR.\n";
	}
	return;
    }

    foreach $addr (@addrs) {
	$comments .= " " . $Comments{"$canonical-$addr"};
    }

    # Be liberal in what we accept, e.g.,
    #
    #   [rp=first.last@host"text"]  [ rp = first.last@host "text" ]
    #   [rp = first.last@host random "text" string ]
    #
    #   all result in RP  MAILBOX  = first\.last.host
    #                 RP  TXTDNAME = current canonical domain name
    #                 TXT RDATA    = "text"
    #
    #   [rp=first.last@host]  [rp= first.last@host "" ]
    #   [rp = first.last@host random "" string ]
    #   [rp = first.last@host random  string ]
    #
    #   all result in RP  MAILBOX  = first\.last.host
    #                 RP  TXTDNAME = . (root zone placeholder)
    #                 no TXT record
    #
    #   [rp="text"]  [ rp = "text" ]  [rp = "text" random string ]
    #
    #   all result in RP  MAILBOX  = . (root zone placeholder)
    #                 RP  TXTDNAME = current canonical domain name
    #                 TXT RDATA    = "text"
    #
    if ($comments ~~ /\[\s*rp\s*=\s*([^\s"]+)?[^"]*("[^"]*")?[^\]]*\]/i) {
	$rp = ($1) ?? $1 !! ".";
	$rp_txt = ($2) ?? $2 !! "";
	$rp_txt ~~ s/"//g;
	if ($rp ~~ /@/) {
	    ($user_part, $domain_part) = split(/@/, $rp, 2);
	    $user_part ~~ s/[.]/\\./g;		# escape "." in username
	    1 while $user_part ~~ s/\\\\/\\/g;	# remove redundancies
	    if ($domain_part ~~ /[.]/) {	# multiple domain labels
		$domain_part .= ".";		# append root domain
	    }					# relative domain fmt. otherwise
	    $rp = "$user_part.$domain_part";	# rejoin w/ unescaped "."
	} elsif ($rp !~ /[.]$/) {		# proceed if no trailing "."
	    $rp ~~ s/[.]/\\./g;			# treat as username & escape "."
	    1 while $rp ~~ s/\\\\/\\/g;		# remove redundancies
	}					# leave username in relative fmt
	$rp ~~ s/[.][.]/./g;			# remove redundant "." chars.
	PRINTF(*DOMAIN, "%s%s\tRP\t%s %s\n",
	       ($canonical eq $Owner_Field ?? "\t\t" !! TAB($canonical, 16)),
	       $ttl, $rp, ($rp_txt eq "" ?? "." !! "$canonical"));
	if (exists($RRowners{$canonical})) {
	    unless ($RRowners{$canonical} ~~ / RP /) {
		$RRowners{$canonical} .= "RP ";
	    }
	} else {
	    $RRowners{$canonical} = " RP ";
	}
	unless ($rp_txt eq "") {
	    PRINTF(*DOMAIN, "%s%s\tTXT\t\"%s\"\n", "\t\t", $ttl, $rp_txt);
	    unless ($RRowners{$canonical} ~~ / TXT /) {
		$RRowners{$canonical} .= "TXT "
	    }
	}
	$Owner_Field = $canonical;
    }
    return;
}


#
# Generate resource records (CNAME or A) for the aliases of a
# canonical name.  This subroutine is called after the generation
# of all of the canonical name's other RRs (A, MX, TXT, etc.).
#
sub CNAME {
    my ($canonical, $ttl, @addrs) = @_;
    my ($action, $addr, $alias, $cmode, $common_alias, $data, $default_method);
    my ($error, $interface_alias, $make_rr, $netpat, $num_addrs, $ptr_file);
    my ($ptr_owner, $rr_written, $tmp);
    my (@aliases);

    $rr_written = 0;
    $num_addrs = @addrs;
    foreach $addr (@addrs) {
	#
	# If this is a single-address host, print a CNAME record
	# for each alias.
	#
	# If this is a multi-homed host, perform the following tasks
	# for each alias of each IP address:
	#
	#   1. Identify aliases that are common to all addresses.
	#      If possible, a CNAME pointing to the canonical name
	#      will be created.
	#
	#   2. The first non-common alias will be assigned an A record
	#      and, if enabled, the appropriate MX RRset.
	#
	#   3. If the default method of handling multi-homed hosts is
	#      in effect, then do the following:
	#
	#      * Subsequent non-common aliases are assigned the same
	#        RRset(s) as the first alias in step #2.
	#
	#      Otherwise, generate the rest of the forward-mapping RRs
	#      for the multi-homed host using the following alternative:
	#
	#      * Subsequent non-common aliases will be assigned a CNAME
	#        that points to the A record created in step #2.
	#
	if ($num_addrs > 1) {
	    #
	    # Each address of a multi-homed host may specify how the
	    # forward- and reverse-mapping RRsets get generated via
	    # the "[mh=??]" flag together with the +m option.
	    # Determine the forward-mapping method that's now in effect.
	    #
	    unless ($Multi_Homed_Mode ~~ /C/) {
		#
		# Use the default method unless overridden.
		#
		$default_method = ($Comments{"$canonical-$addr"}
				  ~~ /\[\s*mh\s*=\s*(?:c|cp|pc)\s*\]/i) ?? 0 !! 1;
	    } else {
		#
		# Use the alternate method unless overridden.
		# NOTE: Absence of the "c" specification in the
		#       comment flag signifies an override condition.
		#
		$default_method = ($Comments{"$canonical-$addr"}
				   ~~ /\[\s*mh\s*=\s*[dp]\s*\]/i) ?? 1 !! 0;
	    }
	}
	@aliases = split(' ', $Aliases{"$canonical-$addr"});
	$interface_alias = "";
	foreach $alias (@aliases) {
	    #
	    # Skip over the alias if it and the canonical name differ
	    # only in that one of them has the domain appended to it.
	    #
	    $alias ~~ s/$Domain_Pattern$//io;

	    # If "$UseDefaultDomain" is in effect (-d domain mode=D),
	    # the following typo is not caught when the host file is
	    # read by the main section of the program:
	    #
	    #   host.domain   (correct)
	    #   host .domain  (typo)
	    #
	    # The ".domain" fragment gets interpreted as an alias and will
	    # be rendered to the null string by the previous statement.
	    # Make sure that null aliases are also skipped over.
	    # Otherwise, havoc will ensue later in this subroutine.
	    #
	    next if !$alias || $alias eq $canonical;

	    if ($num_addrs == 1) {
		$common_alias = 0;
	    } else {
		#
		# If the alias exists for *all* addresses of this host,
		# we can use a CNAME instead of an Address record.
		#
		$common_alias = 1;
		foreach $tmp (@addrs) {
		    next if $Aliases{"$canonical-$tmp"} ~~ / $alias /;
		    $common_alias = 0;
		    last;
		}
	    }

	    if ($num_addrs > 1 && !$common_alias && !$interface_alias) {
		unless ($default_method) {
		    #
		    # Only the current alias will be assigned an A record.
		    # Subsequent non-common aliases will be assigned CNAME
		    # records that point back to this one.
		    # Initialize the $interface_alias variable with the
		    # domain name to which the CNAME(s) will reference.
		    # The variable assignment will also prevent subsequent
		    # aliases of the current address from being processed
		    # by this A-record block.
		    #
		    $interface_alias = $alias;
		}
		if (exists($RRowners{$alias})
		    && $RRowners{$alias} ~~ / CNAME /) {
		    if ($Verbose) {
			print STDERR "Can't create A record for `$alias' ",
				     "due to an existing CNAME RR.\n";
		    }
		    $make_rr = 0;
		} else {
		    $make_rr = 1;
		    $error = CHECK_NAME($alias, 'A');
		    if ($error) {
			$action = ($error == 3) ?? "Skipping" !! $DefAction;
			$make_rr = 0 unless $action eq "Warning";
			if ($Verbose) {
			    if ($make_rr) {
				print STDERR "Warning: non-RFC-compliant ",
					     "Address record (`$alias') ",
					     "being generated.\n";
			    } else {
				print STDERR "Cannot generate Address record ",
					     "for `$alias' (invalid hostname).",
					     "\n";
			    }
			    print STDERR "It is an alias for `$canonical' but ",
					 "CNAME not possible (multi-homed).\n";
			}
		    }
		}
		if ($make_rr) {
		    PRINTF(*DOMAIN, "%s%s\tA\t%s\n",
			   ($alias eq $Owner_Field ?? "\t\t" !! TAB($alias, 16)),
			   $ttl, $addr);
		    $Owner_Field = $alias;
		    $rr_written = 1;
		    #
		    # Keep track of domain names that now have Address RRs
		    # assigned to them (we can't make these registrations
		    # in the %Hosts hash because we are in a loop that is
		    # serially reading that data structure with the each()
		    # function).
		    # This data will be used to prevent the creation
		    # of conflicting CNAMEs and, if auditing is enabled,
		    # to make sure that in-domain NS and MX RRs point to
		    # domain names that have at least one Address record.
		    #
		    if (exists($RRowners{$alias})) {
			unless ($RRowners{$alias} ~~ / A /) {
			    $RRowners{$alias} .= "A ";
			}
		    } else {
			$RRowners{$alias} = " A ";
		    }
		    $data = $alias;
		    while ($data ~~ /(?:\\[.]|[^.])*[.]/) {
			#
			# The unqualified alias consists of two or more labels.
			# Register the interior labels in the %RRowners hash
			# so that we can correctly distinguish between a
			# non-existent domain name and a domain name with no
			# DNS resource records during the auditing phase.
			#
			$data ~~ s/(?:\\[.]|[^.])*[.]//;  # strip leading label
			$RRowners{$data} = " " unless exists($RRowners{$data});
		    }

		    if ($Do_MX) {
			#
			# Ensure that every Address RR has the accompanying
			# MX RRset.  First, however, the comment flags that
			# are tied to the canonical name of this particular
			# address must be copied to a key based on the current
			# alias.
			#
			$Comments{"$alias-$addr"} =
						  $Comments{"$canonical-$addr"};
			MX($alias, $ttl, ($addr));
		    }

		    if (exists($Deferred_PTR{"$canonical-$addr"})) {
			#
			# Update the deferred PTR hash so that reverse-mapping
			# queries are answered with the unique interface name
			# instead of the multi-address canonical name.
			#
			($ptr_file, $ptr_owner, $tmp) =
			       split(' ', $Deferred_PTR{"$canonical-$addr"}, 3);
			$Pending_PTR{$ptr_file}{$ptr_owner} = "$alias $tmp";
			delete($Deferred_PTR{"$canonical-$addr"});
		    }
		}
	    } else {
		#
		# CNAME creation block.
		#
		# First check if the alias name already owns some other
		# resource record(s).
		#
		if (exists($RRowners{$alias})) {
		    #
		    # Accommodate any DNSSEC-related RRs from a `spcl'
		    # file that are allowed to co-exist with CNAMEs.
		    #
		    $tmp = $RRowners{$alias};
		    1 while $tmp ~~ s/ (?:$DNSSEC_RRtypes) / /go;
		} else {
		    $tmp = " ";
		}
		if ($tmp ne " " || exists($Hosts{$alias})) {
		    #
		    # The alias name already owns some other resource
		    # record(s).  Normally, this is cause for immediate
		    # rejection since CNAMEs can't coexist with any other
		    # record type.  However, if we are dealing with an alias
		    # that is common to all entries of a multi-homed host,
		    # we can bypass this restriction by creating A records
		    # instead.
		    #
		    $make_rr = 0;
		    unless ($tmp ~~ / CNAME /) {
			if ($common_alias && !exists($Hosts{$alias})) {
			    #
			    # As long as the common alias name does not also
			    # exist as a canonical name in the host file, we'll
			    # be flexible and allow this common name to refer
			    # to the collection of IP addresses of this multi-
			    # homed host via A records.
			    #
			    $make_rr = 1;
			}
		    }
		    unless ($make_rr) {
			if ($Verbose) {
			    print STDERR "Resource record already exists ",
					 "for `$alias'; alias ignored.\n";
			}
		    } else {
			$error = CHECK_NAME($alias, 'A');
			if ($error) {
			    $action = ($error == 3) ?? "Skipping" !! $DefAction;
			    $make_rr = 0 unless $action eq "Warning";
			    if ($Verbose) {
				if ($make_rr) {
				    print STDERR "Warning: non-RFC-compliant ",
						 "Address record (`$alias') ",
						 "being generated.\n";
				} else {
				    print STDERR "Cannot generate Address ",
						 "record for `$alias' ",
						 "(invalid hostname).\n";
				}
				print STDERR "It is an alias for `$canonical' ",
					     "but CNAME not possible ",
					     "(multi-homed).\n";
			    }
			}
		    }
		    if ($make_rr) {
			foreach $tmp (@addrs) {
			    PRINTF(*DOMAIN, "%s%s\tA\t%s\n",
				   ($alias eq $Owner_Field ?? "\t\t"
							   !! TAB($alias, 16)),
				   $ttl, $tmp);
			    $Owner_Field = $alias;
			}
			$rr_written = 1;
			if (exists($RRowners{$alias})) {
			    unless ($RRowners{$alias} ~~ / A /) {
				$RRowners{$alias} .= "A ";
			    }
			} else {
			    $RRowners{$alias} = " A ";
			}
			$data = $alias;
			while ($data ~~ /(?:\\[.]|[^.])*[.]/) {
			    $data ~~ s/(?:\\[.]|[^.])*[.]//;
			    unless (exists($RRowners{$data})) {
				$RRowners{$data} = " ";
			    }
			}
			if ($Do_MX) {
			    $Comments{"$alias-$addr"} =
						  $Comments{"$canonical-$addr"};
			    MX($alias, $ttl, ($addr));
			}
		    }
		} else {
		    $make_rr = 1;
		    $error = CHECK_NAME($alias, 'CNAME');
		    if ($error) {
			$action = ($error == 3) ?? "Skipping" !! $DefAction;
			$make_rr = 0 unless $action eq "Warning";
			if ($Verbose) {
			    if ($make_rr) {
				print STDERR "Warning: creating ",
					     "non-RFC-compliant CNAME record ",
					     "for alias `$alias'.\n";
			    } else {
				print STDERR "Cannot create CNAME record for ",
					     "`$alias' (invalid alias).\n";
			    }
			}
		    }
		    if ($make_rr) {
			if ($num_addrs == 1 || $common_alias) {
			    $tmp = $canonical;
			} else {
			    $tmp = $interface_alias;
			}
			PRINTF(*DOMAIN, "%s%s\tCNAME\t%s\n", TAB($alias, 16),
			       $ttl, $tmp);
			$Owner_Field = $alias;
			$rr_written = 1;
			if (exists($RRowners{$alias})) {
			    $RRowners{$alias} .= "CNAME ";
			} else {
			    $RRowners{$alias} = " CNAME ";
			}
			$data = $alias;
			while ($data ~~ /(?:\\[.]|[^.])*[.]/) {
			    $data ~~ s/(?:\\[.]|[^.])*[.]//;
			    unless (exists($RRowners{$data})) {
				$RRowners{$data} = " ";
			    }
			}
			if ($Audit && $Verbose && $alias ~~ /^\*(?:$|[.])/) {
			    #
			    # Register the wildcard CNAME in the hash
			    # that is reserved for this purpose.
			    #
			    $tmp = $alias;
			    unless ($tmp ~~ /$Domain_Pattern[.]$/io) {
				$tmp .= ".$Domain.";
			    }
			    $tmp ~~ s/^\*[.]//;
			    $Wildcards{$tmp} = " CNAME ";
			}
		    }
		}
	    }

	    if ($common_alias) {
		#
		# Since this common alias has been accounted for by either
		# a CNAME record, multiple A records, or ignored due to a
		# name conflict, remove this name from the alias list so that
		# it's not encountered again for the next address of this host.
		#
		foreach $tmp (@addrs) {
		    $Aliases{"$canonical-$tmp"} ~~ s/ $alias / /;
		}
	    }
	    if ($rr_written && exists($c_Opt_Aliases{$alias})) {
		#
		# RRs for the default domain take precedence over identically-
		# named CNAMEs requested by a -c option with "mode=D".
		# Prevent the generation of an illegal duplicate DNS record
		# by removing the pending domain name from the deferred list.
		#
		($tmp, $netpat, $tmp) = split(' ', $c_Opt_Aliases{$alias}, 3);
		$cmode = $c_Opt_Spec{$netpat}{MODE};
		if ($cmode !~ /Q/ && $Verbose) {
		     print STDERR "Can't create CNAME for ",
				  "`$alias.$c_Opt_Pat_Rel{$netpat}'; ",
				  "another RR exists.\n";
		}
		delete($c_Opt_Aliases{$alias});
	    }
	    $rr_written = 0;
	}
    }
    return;
}


#
# Convert a time period in symbolic notation to the equivalent
# number of seconds.  Repeated time periods are added together
# consistent with the behavior of BIND, e.g.,
#   "1w2d3h2h1d1w"  is calculated identically to "2w3d5h"
#
sub SECONDS {
    my ($input_time) = @_;
    my ($factor, $multiplier, $total_seconds, $unit);

    return $input_time if $input_time ~~ /^\d*$/;
    $total_seconds = 0;
    $input_time = uc($input_time);
    while ($input_time) {
	$input_time ~~ s/^(\d+)([WDHMS])//;
	$factor = $1;
	$unit   = $2;
	if ($unit eq 'W') {
	    $multiplier = 604800;
	} elsif ($unit eq 'D') {
	    $multiplier = 86400;
	} elsif ($unit eq 'H') {
	    $multiplier = 3600;
	} elsif ($unit eq 'M') {
	    $multiplier = 60;
	} else {
	    $multiplier = 1;
	}
	$total_seconds += ($factor * $multiplier);
    }
    return $total_seconds;
}


#
# Convert a time period in seconds to its equivalent symbolic format.
#
sub SYMBOLIC_TIME {
    my ($input_time) = @_;
    my ($factor, $time_string);

    $input_time = uc($input_time) if $input_time ~~ /^\d+[wdhms]$/;
    return $input_time unless $input_time ~~ /^\d+$/;
    return "${input_time}S" if $input_time < 60;
    $time_string = "";
    if ($input_time >= 604800 ) {
	$factor       = int($input_time / 604800);
	$input_time  -= ($factor * 604800);
	$time_string .= "${factor}w";
    }
    if ($input_time >= 86400 ) {
	$factor       = int($input_time / 86400);
	$input_time  -= ($factor * 86400);
	$time_string .= "${factor}d";
    }
    if ($input_time >= 3600 ) {
	$factor       = int($input_time / 3600);
	$input_time  -= ($factor * 3600);
	$time_string .= "${factor}h";
    }
    if ($input_time >= 60 ) {
	$factor       = int($input_time / 60);
	$input_time  -= ($factor * 60);
	$time_string .= "${factor}m";
    }
    $time_string .= "${input_time}s" if $input_time;
    $time_string  = uc($time_string) if $time_string ~~ /^\d+[wdhms]$/;
    return $time_string;
}


#
# Subroutine to increment the SOA serial number according to the
# specifications in RFC-1982.  Called only when a fixed number
# (-i option) or a calendar-based format of YYYYMMDDvv or YYYYMMvvvv
# (-y [mode=D|M] option) is requested for an existing zone data file.
#
# The SOA serial number is an unsigned 32-bit integer that uses
# special arithmetic described in RFC-1982.  Basically, a serial
# number always increases through the range of 0-4294967295 with
# a maximum single increment value of 2147483647 (the maximum
# 31-bit unsigned value).  When an increment causes the value of
# 4294967295 to be exceeded, a wrap-around occurs and the remainder
# is added to zero.  Although the ending number is smaller than the
# starting number in absolute numerical terms, slave name servers will
# treat the wrap-around as a logical increment in the serial number's
# value (as long as the 2147483647 limit is observed) and request a
# transfer of the zone's changed data from the master name server.
# NOTE: Care must be taken to avoid successive increments in the serial
#       number on the master name server that, when taken together,
#       exceed 2147483647 without first making sure that all configured
#       slave name servers (delegated and stealth) are synchronized after
#       each individual increment.  Otherwise, any wrap-around effect will
#       not be noticed and the slaves will treat a smaller serial number
#       on the master as being "older" than their zone copy with a larger
#       numeric value and not transfer the updated zone.
#
# Return list:
#   (serial, flag)
#   serial : incremented SOA serial number
#   flag   : 0 = requested serial number was within the RFC-1982 limit
#            1 = requested serial number was equal to the existing one
#            2 = requested serial number exceeded the RFC-1982 limit
#
sub INCREMENT_SERIAL {
    my ($current_serial) = @_;
    my ($current_month_format, $limit_flag, $new_serial, $tmp_serial);

    if ($New_Serial == $current_serial) {
	#
	# Never return an unchanged serial number.
	#
	if ($New_Serial == 4294967295) {
	    #
	    # Wrap around to the next serial number.  Because of
	    # ambiguities in the way that different name server
	    # implementations treat an SOA serial number of zero,
	    # set the incremented number to one instead.
	    #
	    $new_serial = 1;
	} else {
	    $new_serial = $New_Serial + 1;
	}
	if ($UseDateInSerial) {
	    #
	    # This is effectively the second update of the current
	    # zone data file in the same calendar day.
	    #
	    $limit_flag = 0;
	} else {
	    #
	    # Set the flag to issue a warning that the requested
	    # serial number had to be overridden.
	    #
	    $limit_flag = 1;
	}
	return ($new_serial, $limit_flag);
    }

    if ($New_Serial > $current_serial) {
	if (($New_Serial - $current_serial) <= 2147483647) {
	    #
	    # No special serial number handling is necessary.
	    #
	    return ($New_Serial, 0);
	} else {
	    #
	    # Add the maximum RFC-1982 increment and
	    # return the appropriate warning flag.
	    #
	    $tmp_serial = $current_serial + 2147483647;
	    return ($tmp_serial, 2);
	}
    }

    # Deal with a value of "$New_Serial" that is numerically
    # less than the zone's existing serial number.

    if ($UseDateInSerial) {
	#
	# Take into account the possibility that the current
	# SOA serial number scheme is already calendar based.
	#
	if ($UseDateInSerial > 1 && ($current_serial - $New_Serial) <= 98) {
	    #
	    # This is the expected result for a site that uses the
	    # date-based format of YYYYMMDDvv since it unambiguously
	    # supports 100 changes per calendar day (versions 00 to 99).
	    #
	    $new_serial = $current_serial +1;
	    return ($new_serial, 0);
	}
	#
	# Accommodate busier sites that wish to use a calendar
	# format of YYYYMMvvvv as well as the occasional day
	# when there are more than 100 updates for users of
	# the YYYYMMDDvv format.  This allows for 10,000
	# changes per calendar month.
	#
	if ($UseDateInSerial == 1) {
	    $current_month_format = $New_Serial;
	} else {
	    #
	    # If the date format is YYYYMMDDvv, the "$UseDateInSerial"
	    # variable has been assigned the day-portion of the base
	    # serial number.  Subtract it to get the base YYYYMMvvvv
	    # format.
	    #
	    $current_month_format = $New_Serial - $UseDateInSerial;
	}
	if (($current_serial - $current_month_format) <= 9998) {
	    $new_serial = $current_serial +1;
	    return ($new_serial, 0);
	}
	# Not returning to the caller from this block implies the
	# remaining scenario in which the hostmaster is changing
	# to the calendar-based format from an ordinary serial
	# number which is greater by 10000 or more.
    }

    # Since the requested serial number is numerically less than
    # the current serial number, we must wrap around the maximum
    # serial number value of 4294967295 either now or the next
    # time that `h2n' is run in order to properly set the new
    # serial number.

    if ($current_serial <= 2147483648) {
	#
	# The wrap-around can not occur now because of the
	# maximum increment limitation.  Go as far as we can
	# and set the limit flag.
	#
	$tmp_serial = $current_serial + 2147483647;
	return ($tmp_serial, 2);
    }
    if ($New_Serial == 0) {
	#
	# Even though this SOA serial number is not recommended,
	# the user has chosen this value anyway.  Make it so,
	# since we are within the maximum increment range.
	# By explicitly accounting for this possibility here, we
	# can purposely avoid setting an interim serial number of
	# zero in the next block.
	#
	return (0, 0);
    }
    $tmp_serial = 2147483646 - (4294967295 - $current_serial);
    if ($tmp_serial < $New_Serial) {
	#
	# The wrap-around falls short of reaching the requested serial
	# number.  Add the maximum increment to the current serial and
	# set the limit flag.  If the computed interim serial number is
	# zero, subtract one to avoid possible interoperability issues.
	#
	$tmp_serial = 4294967295 if $tmp_serial == 0;
	return ($tmp_serial, 2);
    } else {
	#
	# The requested serial number can be reached from the current
	# serial number within the maximum increment limit by wrapping
	# around the maximum serial number.
	#
	return ($New_Serial, 0);
    }
}


#
# Subroutine to create the zone apex records (SOA and NS) at the beginning
# of the db file.  If the -T option was specified, additional zone apex
# records for the forward-mapping domain will also be added.
# A $TTL directive will appear at the beginning of the db file unless
# our RFC-2308 status specifically prohibits it.
#
# Return values:
#   0 = desired SOA serial number denied due to RFC-1982 limits
#   1 = no SOA serial number warnings
#
sub MAKE_SOA {
    (my $fname, my $uq_fname, local *FILEH) = @_;
    my ($current_serial, $data, $error, $found_ttl_directive, $limit_flag);
    my ($message, $new_serial, $rdata, $rrtype, $s, $serial, $soa_expire);
    my ($soa_minimum, $soa_mname, $soa_refresh, $soa_retry, $soa_rname);
    my ($soa_warned, $tmp, $ttl, $ttl_directive, @soa_fields);

    if (-e "$fname.log" || -e "$fname.jnl") {
	#
	# Not good.  The presence of a BIND 8 log file or BIND 9
	# journal file indicates that this is a dynamic zone.
	# Dynamic zones *must* be dynamically updated.
	# The risk of data loss is high if `h2n' is allowed
	# to overwrite a dynamic zone with a relatively static
	# snapshot of the host file data.
	#
	print STDERR "Dynamic zone log/journal found for `$fname'.\n",
		     "I refuse to risk loss of data ... sorry.\n";
	exit(2);
    }
    if (-s $fname) {
	$found_ttl_directive = 0;
	unless (open(*FILEH, '<', $fname)) {
	    print STDERR "Couldn't open `$fname' for reading in MAKE_SOA().\n",
			 "Error: $!\n";
	    GIVE_UP();
	}
	$_ = <FILEH>;
	if (/^\s*$/ || /^\s*;/ || /^\$ORIGIN\s+/) {
	    #
	    # We've encountered a zone file that was not created by
	    # us.  We'll deal with two possibilities.
	    #
	    if (/^;BIND DUMP/) {
		#
		# Not good.  This fits the profile of a dynamic zone
		# snapshot that BIND periodically dumps to disk.
		#
		print STDERR "Dynamic zone format encountered in `$fname'.\n",
			     "I refuse to risk loss of data ... sorry.\n";
		exit(2);
	    } else {
		#
		# Some sites may want to copy zone files from a slave
		# name server and/or an AXFR query from a utility like DiG.
		# Deal with this possibility by skipping over the comment
		# lines and/or $ORIGIN directive that precede the SOA record.
		#
		while (/^\s*$/ || /^\s*;/ || /^\$ORIGIN\s+/) { $_ = <FILEH>; }
	    }
	}
	chop;
	if (/^\$TTL\s+([^;]+)/) {
	    $ttl_directive = $1;
	    $found_ttl_directive = 1;
	    if ($RFC_2308 == 1 && $BIND_Version_Num == 0) {
		#
		# We are here because our RFC-2308 status was specifically
		# cancelled via the -o option *and* the FIXUP subroutine could
		# not determine the version of BIND on the master name server.
		# Under these two circumstances, the "$RFC_2308" flag is set
		# to the "soft" value of 1.
		# Discovery of an existing $TTL directive overrides this
		# tentative condition and firmly establishes RFC-2308 status.
		# Now that this status is known, follow the same course
		# of action as documented by the comments in the relevant
		# section of FIXUP.
		#
		$RFC_2308 = 2;
		$Master_Ttl = $Ttl if $Ttl;
		$Ttl = $DefNegCache;
	    }
	    $_ = <FILEH>;
	    chop;
	}
	if (/\s\(\s*$/) {
	    unless ($soa_warned) {
		if ($Verbose) {
		    print STDOUT "Converting SOA format to new style.\n";
		}
		$soa_warned = 1;
	    }
	    # The SOA record is split across more than one line.
	    # Although any combination is theoretically possible,
	    # only two variations occur in real life.  Either the
	    # SOA serial and timer fields are all on the next line
	    # or these fields appear individually on the next five
	    # lines.
	    #
	    $soa_refresh = "";
	    $_ = <FILEH>;
	    if (/\s\)\s*$/) {
		#
		# The rest of the SOA RR has just been read.
		#
		($current_serial, $soa_refresh, $soa_retry,
		 $soa_expire, $soa_minimum, $tmp) = split(' ', $_, 6);
	    } else {
		#
		# All we have is the serial number so far.
		#
		($current_serial, $tmp) = split(' ', $_, 2);
	    }
	    if (!$soa_refresh && (!$Refresh || !$Retry || !$Expire || !$Ttl)) {
		#
		# The rest of the SOA fields have not yet been obtained
		# and we need to preserve one or more SOA timer values.
		#
		($soa_refresh, $tmp) = split(' ', <FILEH>, 2);
		($soa_retry, $tmp) = split(' ', <FILEH>, 2);
		($soa_expire, $tmp) = split(' ', <FILEH>, 2);
		($soa_minimum, $tmp) = split(' ', <FILEH>, 2);
	    }
	    # Preserve existing SOA timer values in the absence
	    # of a replacement value passed via the -o/+t options.
	    #
	    $soa_refresh = $Refresh if $Refresh;
	    $soa_retry = $Retry if $Retry;
	    $soa_expire = $Expire if $Expire;
	    $soa_minimum = $Ttl if $Ttl;
	} else {
	    if (/^(.*?\s)SOA\s+(.+)/i) {
		$error = 0;
		$tmp = $1;
		$rdata = $2;
		$rdata ~~ s/[()]//g;
		@soa_fields = split(' ', $rdata);
		if ($#soa_fields == 6) {
		    $current_serial = $soa_fields[2];
		    $soa_refresh = ($Refresh) ?? $Refresh !! $soa_fields[3];
		    $soa_retry = ($Retry) ?? $Retry !! $soa_fields[4];
		    $soa_expire = ($Expire) ?? $Expire !! $soa_fields[5];
		    $soa_minimum = ($Ttl) ?? $Ttl !! $soa_fields[6];
		} else {
		    $error = 1;
		}
	    } else {
		$error = 1;
	    }
	    if ($error) {
		print STDERR "Improper format SOA in `$fname'.\n";
		GIVE_UP();
	    }
	}
	unless (defined($New_Serial)) {
	    if ($current_serial == 4294967295) {
		#
		# Although the next serial number wraps around to zero,
		# skip this value to avoid potential interoperability
		# issues that different name server implementations may
		# have with an SOA serial number of zero.
		#
		$new_serial = 1;
	    } else {
		$new_serial = $current_serial + 1;
	    }
	} else {
	    ($new_serial, $limit_flag) = INCREMENT_SERIAL($current_serial);
	}
	if ($RFC_2308 == 2 && !$found_ttl_directive) {
	    #
	    # The existing zone file we just read did not have a $TTL
	    # directive but one will appear in the replacement zone file.
	    # This means that the SOA Minimum field will switch its
	    # context from a TTL value to a Negative Caching TTL value.
	    # Because existing SOA fields are preserved unless explicitly
	    # set via the -o/+t options, make sure that the SOA Minimum
	    # field is replaced by a suitable default value in the absence
	    # of one from -o/+t.
	    #
	    $soa_minimum = ($Ttl) ?? $Ttl !! $DefNegCache;
	}
	close(*FILEH);
    } else {
	#
	# Since this is a new zone file, any valid serial number
	# can be assigned without having to do RFC-1982 arithmetic.
	#
	$new_serial = (defined($New_Serial)) ?? $New_Serial !! $DefSerial;
	$soa_refresh = ($Refresh) ?? $Refresh !! $DefRefresh;
	$soa_retry = ($Retry) ?? $Retry !! $DefRetry;
	$soa_expire = ($Expire) ?? $Expire !! $DefExpire;
	if ($RFC_2308 == 2) {
	    $soa_minimum = ($Ttl) ?? $Ttl !! $DefNegCache;
	} else {
	    $soa_minimum = ($Ttl) ?? $Ttl !! $DefTtl;
	}
    }

    unless (open(*FILEH, '>', $fname)) {
	print STDERR "Couldn't open `$fname' for writing in MAKE_SOA()\n",
		     "Error: $!\n";
	GIVE_UP();
    }

    $soa_mname = $RespHost;
    $soa_rname = $RespUser;
    if ($uq_fname eq $Domainfile) {
	#
	# Make a cosmetic indulgence by keeping in-domain names
	# relative to the origin in the forward-mapping file.
	#
	$soa_mname ~~ s/$Domain_Pattern[.]$//io;
	$soa_rname ~~ s/$Domain_Pattern[.]$//io;
    }
    if ($Need_Numeric_Ttl) {
	$soa_refresh = SECONDS($soa_refresh);
	$soa_retry   = SECONDS($soa_retry);
	$soa_expire  = SECONDS($soa_expire);
	$soa_minimum = SECONDS($soa_minimum);
    } else {
	$soa_refresh = SYMBOLIC_TIME($soa_refresh);
	$soa_retry   = SYMBOLIC_TIME($soa_retry);
	$soa_expire  = SYMBOLIC_TIME($soa_expire);
	$soa_minimum = SYMBOLIC_TIME($soa_minimum);
    }
    if ($RFC_2308 == 2) {
	$ttl_directive = $Master_Ttl if $Master_Ttl;
	$ttl_directive = $DefTtl unless $ttl_directive;
	$ttl_directive = ($Need_Numeric_Ttl) ?? SECONDS($ttl_directive)
					     !! SYMBOLIC_TIME($ttl_directive);
	print FILEH "\$TTL $ttl_directive\n",
		    "\@\tSOA\t$soa_mname $soa_rname";
    } else {
	#
	# If no $TTL directive is to be written, RFC-1035 requires the first
	# record of the zone file to have an explicitly-specified TTL field.
	#
	printf FILEH "\@ %5s SOA\t%s %s", $soa_minimum, $soa_mname, $soa_rname;
    }
    print FILEH " ( $new_serial $soa_refresh $soa_retry $soa_expire",
		" $soa_minimum )\n";
    foreach $s (@Full_Servers) {
	$tmp = $s;
	$tmp ~~ s/$Domain_Pattern[.]$//io if $uq_fname eq $Domainfile;
	print FILEH "\tNS\t$tmp\n";
    }
    if (exists($Partial_Servers{$uq_fname})) {
	foreach $s (split(' ', $Partial_Servers{$uq_fname})) {
	    $tmp = $s;
	    $tmp ~~ s/$Domain_Pattern[.]$//io if $uq_fname eq $Domainfile;
	    print FILEH "\tNS\t$tmp\n";
	}
    } elsif (!@Full_Servers) {
	#
	# Add name server in MNAME field of SOA record if missing -s/-S
	#
	print FILEH "\tNS\t$soa_mname\n";
    }
    if ($uq_fname eq $Domainfile && keys(%Apex_RRs)) {
	#
	# Add additional records from the -T option.  These RRs
	# have already been submitted to READ_RRs() for validation
	# and registration into the appropriate data structures.
	#
	foreach $rrtype (keys %Apex_RRs) {
	    foreach $data (@{ $Apex_RRs{$rrtype} }) {
		$rdata = $data;
		if ($rdata ~~ /\n$/) {
		    #
		    # A newline appended to the "$rdata" string is a
		    # data structure signal to indicate that this is
		    # a continuation line of a multi-line record.
		    #
		    $rdata ~~ s/\n$//;
		    if ($rdata ~~ /\n$/) {
			#
			# Besides this being a continuation line, a second
			# appended newline signifies that the previous line
			# ended with an open quote in effect.  Therefore,
			# the usual cosmetic indentation must not be added
			# in order to maintain data integrity.
			#
			print FILEH $rdata;
		    } else {
			print FILEH "\t\t$rdata\n";
		    }
		} else {
		    ($ttl, $rdata) = split(/,/, $rdata, 2);
		    $ttl = ($Need_Numeric_Ttl) ?? SECONDS($ttl)
					       !! SYMBOLIC_TIME($ttl);
		    printf FILEH " %6s %s\t%s\n", $ttl, $rrtype, $rdata;
		}
	    }
	}
    }
    print FILEH "\n";
    $DB_Filehandle{*FILEH} = $fname;
    CLOSE(*FILEH);		# CLOSE() will begin the management of %LRUtable

    unless ($limit_flag) {
	return 1;
    } elsif ($limit_flag == 1) {
	($message = <<"EOT") ~~ s/^\s+\|//gm;
	|Warning: SOA serial number for db file `$uq_fname' was already
	|         set to the requested value of $New_Serial.  It has been
	|         incremented to $new_serial instead.
EOT
	print STDERR "$message\n";
	return 1;
    } else {
	($message = <<"EOT") ~~ s/^\s+\|//gm;
	|Warning: SOA serial increment from $current_serial to $New_Serial for db file
	|         `$uq_fname' exceeds the RFC-1982 maximum of 2147483647.
	|         To prevent zone propagation failures, only the maximum increment
	|         was applied; the serial number is set to $new_serial instead.
EOT
	print STDERR "$message\n";
	return 0;
    }
}


#
# Initialize database files with new or updated SOA records.
#
sub INITDBs {
    my $loopback_soa_incremented = 0;
    my $warning = 0;
    my ($alias, $file_handle, $file_name, $lc_alias, $message);
    my ($ttl, $zone_entry);

    foreach $zone_entry (@Make_SOA) {
	($file_name, $file_handle) = split(' ', $zone_entry, 2);
	$loopback_soa_incremented = 1 if $file_name eq "db.127.0.0";
	unless (MAKE_SOA("$Search_Dir/$file_name", $file_name, $file_handle)) {
	    $warning = 1
	}
    }
    unless (exists($RRowners{localhost})) {
	#
	# Since the -T option argument 'ALIAS=localhost' was not specified,
	# make the address record for `localhost' appear as the first
	# non-top-of-zone-related RR in the forward-mapping zone for "$Domain".
	#
	PRINTF(*DOMAIN, "%s\tA\t127.0.0.1\n", "localhost\t");
	$RRowners{localhost} = " A ";
    }
    if (keys(%Apex_Aliases)) {
	#
	# Add any CNAMEs that were configured with the `ALIAS=' keyword
	# of the -T option.  These always point to the zone apex.
	# NOTE: These aliases have already been registered in the
	#       "%RRowners" hash when they were submitted to
	#       READ_RRs() for validation by FIXUP().
	#
	while (($lc_alias, $alias) = each %Apex_Aliases) {
	    ($alias, $ttl) = split(' ', $alias, 2);
	    if ($Need_Numeric_Ttl) {
		$ttl = SECONDS($ttl);
	    } else {
		$ttl = SYMBOLIC_TIME($ttl);
	    }
	    PRINTF(*DOMAIN, "%s%s\tCNAME\t\@\n", TAB($alias, 16), $ttl);
	}
    }
    if ($MakeLoopbackSOA) {
	$file_handle = "DB.127.0.0";
	unless ($loopback_soa_incremented) {
	    $file_name = "db.127.0.0";
	    $warning = 1 unless MAKE_SOA("$Search_Dir/db.127.0.0", $file_name,
					 $file_handle);
	}
	PRINTF($file_handle, "1\t\tPTR\tlocalhost.\n");
    }
    if ($warning) {
	($message = <<'EOT') ~~ s/^\s+\|//gm;
	|
	|    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
	|    !!                                                              !!
	|    !! IMPORTANT: Do *not* run this program again until all of the  !!
	|    !!            zones affected by the SOA serial number warnings  !!
	|    !!            have propagated to *all* of their configured      !!
	|    !!            (both delegated and stealth) slave name servers.  !!
	|    !!            Failure to do so might cause some slaves to treat !!
	|    !!            their SOA serial numbers as being "greater" than  !!
	|    !!            the effective serial number on the master server. !!
	|    !!                                                              !!
	|    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
EOT
	print STDERR "$message\n";
    }
    return;
}


#
# Take a Left-Hand-Side or Right-Hand-Side template specification
# passed via the BIND $GENERATE directive and return a specially-
# formatted string.  This subroutine's caller, READ_RRs(), will
# then generate the appropriate owner name/RDATA fields by using
# the eval() function on the returned LHS and RHS strings.
#
# Return values:
#    "eval_string": successful $GENERATE template -> eval() string conversion
#            undef: invalid $GENERATE template specification encountered
#
sub GEN_NAME {
    my ($template) = @_;
    my ($eval_string, $offset, $prefix, $radix, $suffix, $width);

    $eval_string = '""';
    $template ~~ s/\$\$/\\\$/g;	    # "$$" -> "\$" for backwards compatibility
    while ($template) {
	unless ($template ~~ /([^\$]+)?\$(.*)/) {
	    #
	    # We are finished - there are no more "$" characters.
	    # Append what's left of "$template" to "$eval_string"
	    # and set "$template" to null so that the loop exits.
	    #
	    $eval_string .= " . \"$template\"";
	    $template = "";
	} else {
	    #
	    # A "$" character exists.  Append whatever appears in front
	    # of it to "$eval_string".  "$template" is re-assigned with
	    # whatever appears after the "$" character.
	    #
	    $prefix = (defined($1)) ?? $1 !! "";
	    $suffix = (defined($2)) ?? $2 !! "";
	    $eval_string .= " . \"$prefix\"";
	    $template = $suffix;
	    if ($eval_string ~~ /\\\"$/) {
		#
		# It turns out that an escape character preceded the "$"
		# that was just found thus rendering it as just another
		# character.
		# Replace the escape character with the "$" character that
		# was removed from the end of the "$eval_string" variable
		# and proceed to the next loop iteration.
		#
		$eval_string ~~ s/\\\"$/\$\"/;
	    } else {
		#
		# The "$" character is indeed an iterator replacement symbol.
		# Now see if it is followed by a format specification.
		#
		unless ($template ~~ /^{/) {
		    #
		    # No format specification appears after the "$" character.
		    # Substitute an appended literal iterator variable "$i"
		    # which will be used by READ_RRs() in place of the "$"
		    # iteration token of the BIND $GENERATE template.
		    #
		    $eval_string .= ' . $i';
		} elsif ($template ~~ /^{(-?\d+),*([^,}]+)?,*([^,}]+)?}(.*)/) {
		    #
		    # A valid format specification appears after the "$"
		    # substitution symbol, e.g.,  host${0,3,d}
		    # NOTE: As of version 9.2.0, BIND doesn't complain if
		    #       the `width' and `radix' fields do not consist of
		    #       digits and the pattern [doxX], respectively, i.e.,
		    #       host${9,foo,zoo} silently defaults to host${9,0,d}.
		    #
		    $offset = $1;
		    $width = $2;
		    $radix = $3;
		    $template = $4;
		    unless (defined($width) && $width ~~ /^\d+$/) {
			$width = 0;
		    } else {
			$width = "0$width";	# prepend "0" for zero-padding
		    }
		    $radix = "d" unless defined($radix) && $radix ~~ /^[doxX]$/;
		    $eval_string .= " . sprintf(\"%${width}${radix}\", "
				 .  '($i + ' . "$offset))";
		} else {
		    #
		    # The BIND $GENERATE template specification is invalid.
		    #
		    return;
		}
	    }
	}
    }
    # To keep things simple, the template translator always precedes
    # a data substring with the "." concatenation character before
    # appending it to "$eval_string".  This results in one or more
    # consecutive NO-OP concatenations ("" . ) at the start of each
    # "$eval_string".  Remove them to eliminate unnecessary processing
    # by eval() in READ_RRs().
    #
    1 while $eval_string ~~ s/^\"\" . //g;
    return $eval_string;
}


#
# Read and parse resource records in master zone file format so that
# the following may be done:
#   * Store information about in-domain owner names in order to prevent
#     (detect in verify mode) the creation (existence) of conflicting
#     CNAMEs (forward-mapping files only).
#   * Store information about the RDATA fields of NS, MX, PTR, SRV, RT,
#     and AFSDB records for later reporting in case these RRs are found
#     to be not pointing to domain names with A records.
#   * Store information about the TXTDNAME field of RP RRs so that
#     missing TXT records can be identified.
#   * Store information about the RDATA field of CNAME RRs so that
#     dangling CNAMEs can be identified.
#   * Keep track of wildcard RRs and child domains so that the
#     auditing of the various record types can be done properly.
#   * Report RFC-1123 errors with owner-names and RDATA domain names plus
#     errors with malformed IP addresses.
#
# Return values:
#   0 = no warnings
#   1 = warnings
#   2 = file open error
#
sub READ_RRs {
    my ($rr_data, $zone, $origin, $owner, $warning_status) = @_;
    my ($bad_record, $char, $continuation_line, $data, $data2, $default_ttl);
    my ($domain_pattern, $error, $gen_class, $gen_file, $gen_owner, $gen_rdata);
    my ($gen_ttl, $i, $include_file, $label_count, $last_char, $lhs);
    my ($line_buffer, $line_num, $message, $n, $new_origin, $open_paren_count);
    my ($open_quote, $original_line, $port, $preference, $protocol, $range);
    my ($rdata, $rdata_fqdn, $rp_mailbox, $rr, $rr_source, $rrtype, $serial);
    my ($service, $show, $split_line_num, $start, $step, $stop, $tmp, $ttl);
    my ($txt_domain, $uq_owner, $weight, $zone_pattern);
    my ($zone_suffix);
    my (@gen_buffer, @tmp);
    local (*FILE, *GEN);

    if (ref($rr_data)) {
	#
	# The resource record data is in an array passed by reference.
	# The first array element holds the name of the `h2n' option
	# or processing section that is responsible for submitting the
	# data so that errors can be properly attributed.
	#
	$rr_source = shift(@$rr_data);
    } else {
	#
	# The resource record data is in a passed filename.
	#
	unless (OPEN(*FILE, '<', $rr_data)) {
	    if ($Verbose) {
		print STDERR "\n" unless $Newline_Printed;
		print STDERR "Couldn't open `$rr_data': $!";
		#
		# The terminating newline will be output
		# by this subroutine's caller.
	    }
	    $Load_Status = 3;
	    $warning_status = $Newline_Printed = 2;
	    return $warning_status;
	}
	($rr_source = $rr_data) ~~ s/^.*\///;
	$rr_source = "`$rr_source'";
    }
    $zone = lc($zone);			  # in case the -P option is in effect
    $origin = lc($origin);		  # ditto
    $domain_pattern = lc($Domain_Pattern); # time-saver to accommodate -P option
    $zone_suffix = ($origin ne '.') ?? ".$origin" !! ".";
    $zone_pattern = $zone;
    #
    # Make sure to escape any Regular Expression metacharacters
    # that may be present in "$zone_pattern".
    #
    $zone_pattern ~~ s/([.\|\\\$\^\+\[\(\)\?'`])/\\$1/g;
    $zone_pattern = "\\.$zone_pattern" if $zone ne '.';
    $message = $ttl = "";
    $continuation_line = $open_paren_count = $open_quote = 0;
    if (defined($Master_Ttl)) {
	$default_ttl = lc($Master_Ttl);
    } elsif (defined($Ttl)) {
	$default_ttl = lc($Ttl);
    } else {
	$default_ttl = lc($DefTtl);
    }
    $line_num = 0;
    #
    # The following code block for reading text in master zone data format
    # and assembling that data into DNS records emulates the strict behavior
    # of the BIND 9 lexer.  DNS records which are not compliant with the
    # syntax specifications of RFC-1035 will be flagged as errors and skipped
    # from further processing.
    # Illegal zone file syntax that the lexers in BIND 4/8 mistakenly
    # allowed must now be fixed.
    #
    while (1) {
	if (ref($rr_data)) {
	    last unless (@$rr_data);
	    $_ = shift(@$rr_data);
	} else {
	    last if eof(*FILE);
	    $_ = <FILE>;
	}
	$line_num++;
	if ($continuation_line || /["()]/) {
	    #
	    # Scan the line character-by-character to identify the
	    # proper context of any quoting characters we find.
	    #
	    unless ($continuation_line) {
		$original_line = $_;
		$line_buffer = "";
		$split_line_num = $line_num;
		$bad_record = 0;
	    } else {
		#
		# As a sanity check for unbalanced quotes/parentheses,
		# keep track of the accumulated length of the concatenated
		# continuation lines and quit reading the zone file if it
		# exceeds a certain threshold.
		# This threshold number was determined by deliberately
		# breaking a zone file and submitting it to the BIND 9
		# utility `named-checkzone'.  The isc_lex_gettoken()
		# call fails with a "ran out of space" error after
		# running through about 131500 bytes (approximately
		# 3000 lines of a typical zone file).
		#
		$original_line .= $_;
		last if length($original_line) > 131500;
	    }

	    # Scan each character in the line while keeping in mind
	    # the following special characters and quoting hierarchy:
	    #
	    #   '\'  ->  An escape (backslash) cancels any special meaning
	    #            of the character that immediately follows.  This
	    #            includes backslashes, double-quotes, semicolons,
	    #            left and right parentheses, and the newline.
	    #
	    #   '"'  ->  The double-quote character quotes whitespace, the
	    #            ";()" characters which are special to RFC-1035,
	    #            and escaped newlines until a matching unescaped
	    #            double-quote is reached.
	    #
	    #   ';'  ->  Signifies the start of a comment.  It and
	    #            the remaining characters that follow are
	    #            ignored up to and including the next escaped
	    #            or unescaped newline character.
	    #
	    #   '('  ->  Signifies that subsequent newline characters
	    #            are to be ignored, i.e., quoted, if encountered.
	    #            Does not perform any other quoting function.
	    #            May be nested to multiple levels.
	    #
	    #   ')'  ->  Cancels the effect of the "(" character at
	    #            the current nesting level.  Newlines are still
	    #            ignored until the outer-most opening "(" is
	    #            balanced by the corresponding ")" character.
	    #
	    #   1. An escaped newline is only valid within matching
	    #      double-quote characters.  The lexer will report
	    #      an "unexpected end of input" error otherwise.
	    #
	    #   2. An unescaped newline effectively cancels an open
	    #      double-quote character.  The lexer will report an
	    #      "unbalanced quotes" error if this situation occurs.
	    #      If, however, there are also one or more open parentheses
	    #      in effect, the lexer will continue to scan for their
	    #      closing ")" counterparts to try to complete the disposition
	    #      of the defective record.  Quoting will be cancelled and
	    #      not be toggled by subsequent double-quote characters until
	    #      the balancing parentheses are found.
	    #
	    #   3. If the nesting level of parentheses goes negative, the
	    #      lexer will immediately report the imbalance and discard
	    #      the rest of the line.  If an odd number of double-quote
	    #      characters are part of the refuse, this may have a
	    #      side-effect of introducing an "unbalanced quotes" error
	    #      in a subsequent line.  Since resynchronization has to
	    #      occur at some point, however, the lexer's chosen priority
	    #      is to balance parentheses.
	    #
	    chop;
	    $last_char = "";	  # don't carry an escape from the previous line
	    while (length($_)) {
		($char, $_) = split(//, $_, 2);
		if ($char eq "\\" && $last_char eq "\\") {
		    #
		    # An escape character which is itself escaped
		    # becomes an ordinary backslash character.
		    # Move it into the buffer and remove its ability
		    # to escape the next character in the byte stream.
		    #
		    $line_buffer .= $char;
		    $last_char = "";
		    next;
		}
		if ($char eq '"' && $last_char ne "\\") {
		    $open_quote = !$open_quote unless $bad_record;
		    $line_buffer .= $char;
		    $last_char = $char;
		    next;
		}
		unless ($open_quote || $last_char eq "\\") {
		    #
		    # Encountering an unquoted and unescaped semicolon
		    # marks the start of a comment.  There is no need
		    # to scan the rest of the line.
		    #
		    last if $char eq ";";
		    #
		    # Unquoted and unescaped parentheses are not part of
		    # the DNS resource record but an RFC-1035 construct
		    # to ignore intervening newlines.
		    # Keep track of them to maintain the current nesting
		    # level but do not include these characters in the
		    # line buffer of the record that we are assembling.
		    #
		    if ($char eq "\(") {
			$open_paren_count++;
			next;
		    }
		    if ($char eq "\)") {
			$open_paren_count--;
			last if $open_paren_count < 0;
			next;
		    }
		}
		if ($open_quote) {
		    if ($char eq "\\" && $last_char ne "\\" && !length($_)) {
			#
			# An escaped newline has been encountered.
			# Replace the backslash with a newline so
			# it can be converted to BIND 9 presentation
			# format in the next block.
			#
			$char = "\n";
		    }
		    if (ord($char) < 32) {
			#
			# Adopt the BIND 9 presentation format in which
			# quoted non-printing characters other than a
			# space get converted into an escape character
			# followed by the non-printing character's
			# three-digit decimal equivalent ASCII value.
			# An escaped newline followed by a tab, for
			# example, would appear as "\010\009".
			#
			$line_buffer .= "\\0";
			$line_buffer .= "0" if ord($char) < 10;
			$line_buffer .= ord($char);
		    } else {
			$line_buffer .= $char;
		    }
		    $last_char = $char;
		} else {
		    #
		    # Preservation of cosmetic whitespace is unnecessary
		    # since the assembled record will be parsed again into
		    # its DNS components, i.e., the owner, TTL, class,
		    # RRtype, and RDATA fields.
		    #
		    $char = " " if $char eq "\t";
		    unless ($char eq " " && $last_char eq " ") {
			$line_buffer .= $char;
			$last_char = $char;
		    }
		}
	    }
	    # Assess the situation now that the character scan
	    # of the current line is complete.
	    #
	    if ($open_paren_count < 0) {
		$message = "Unbalanced parentheses; ";
		if (ref($rr_data)) {
		    $message .= "$rr_source";
		    if ($rr_source ~~ /^-[Ct]/) {
			#
			# Make it clear that this candidate resource record
			# submitted by DO_COMMENTS_TXT() for processing
			# -C/-t options is being ignored and *not* written
			# to the forward-mapping DB file.
			#
			$message .= " (record *not* written to DB file)";
		    }
		} else {
		    $message .= "file `$rr_data', line $line_num";
		}
		print STDERR "$message\n> $original_line";
		$Load_Status = 3;
		$continuation_line = $open_paren_count = 0;
		next;
	    }
	    if ($open_quote && $last_char ne "\n") {
		$message = "Unbalanced quotes; ";
		if (ref($rr_data)) {
		    $message .= "$rr_source";
		    if ($rr_source ~~ /^-[Ct]/) {
			$message .= " (record *not* written to DB file)";
		    }
		} else {
		    $message .= "file `$rr_data', line $line_num";
		}
		print STDERR "$message\n> $original_line";
		$open_quote = 0;
		$Load_Status = 3;
		$bad_record = 1 if $open_paren_count;
		next;
	    }
	    $continuation_line = $open_quote + $open_paren_count;
	    next if $continuation_line || $bad_record;
	    $_ = $line_buffer;
	    next if /^\s*$/;			# line was only a comment
	} else {
	    #
	    # Lex the much simpler case of an ordinary line of text.
	    #
	    next if /^\s*$/ || /^\s*;/;
	    $original_line = $_;
	    s/([^\\]);.*/$1/;			# strip comments
	    if (/\\$/) {
		#
		# Escaped newlines are only valid when quoted.
		#
		$message = "Unexpected end of input; ";
		if (ref($rr_data)) {
		    $message .= "$rr_source";
		    if ($rr_source ~~ /^-[Ct]/) {
			$message .= " (record *not* written to DB file)";
		    }
		} else {
		    $message .= "file `$rr_data', line $line_num";
		}
		print STDERR "$message\n> $original_line";
		$Load_Status = 3;
		next;
	    }
	}
	# The RR parsing pattern expects the RRtype field to be delimited
	# by whitespace at both ends.  A missing RDATA field (normally an
	# error but valid for APL RRs [RFC-3123]) will prevent the RR from
	# matching the pattern unless we make it a practice to always append
	# a space character to each line as it emerges from the lexer.
	# The side-effect of this is that the parsed RDATA field *must*
	# always be chopped of *all* trailing whitespace in order to be
	# properly processed.
	#
	$_ .= " ";
	$rr = 0;
	if (/^[^\$]/ && /^(.*?\s)($RRtypes)\s+(.*)/io) {
	    #                ^                      ^
	    # Note: Minimal matching must be used in the first group of the
	    #       Regular Expression.  Otherwise, the following SOA record
	    #       will be mistakenly matched as an NS record:
	    #
	    #       @      1D IN SOA       ns hostmaster ( 123 3h 1h 1w 10m )
	    #                              ^^
	    #       Also, "$RRtypes" is static during the program's execution.
	    #       Make sure the "compile once" pattern modifier is in place.
	    #
	    $tmp    = lc($1);
	    $rrtype = uc($2);
	    ($rdata = lc($3)) ~~ s/\s+$//;		    # chop whitespace
	    $rr     = 1;
	    $tmp ~~ s/\s+(?:in|hs|ch(?:aos)?|any)\s+/ /;    # strip class
	    if ($tmp ~~ /^\S/) {			    # TTL *may* exist
		($owner, $ttl) = split(' ', $tmp);
		$ttl = $default_ttl unless $ttl;
		#
		# Make sure that all new owner names are fully-qualified.
		#
		1 while $owner ~~ s/\\\\/\\/g;		# strip excess escapes
		$owner  = $origin if $owner eq '@';
		$owner .= $zone_suffix unless $owner ~~ /(?:^|[^\\])[.]$/;
	    } elsif ($tmp ~~ /\S/) {			# TTL field exists
		($ttl = $tmp) ~~ s/\s+//g;
	    } else {					# TTL field is null
		$ttl = $default_ttl;
	    }
	    if ($owner ~~ /$zone_pattern$/ || $owner eq $zone) {
		#
		# Only consider RRs matching the current zone tree.  RRs in
		# child zones will also be processed so that missing glue
		# and/or non-glue records can be reported.
		#
		# Normal mode:
		# ------------
		# Register owner names that are in the forward-mapping
		# domain so that conflicting CNAMEs won't be created.
		# The idea here is that the owner names of already-existing
		# RRs should have priority over potential CNAMEs that have
		# yet to be discovered in the host table.
		#
		# Verify mode:
		# ------------
		# Register owner names as the zone file is read so that
		# CNAME conflicts can be reported.  In both normal mode
		# and verify mode, registered CNAMEs will be used to
		# quickly determine if they are pointed to by the RDATA
		# field of any record type (NS, MX, etc.) that should
		# properly point to the canonical domain name instead.
		#
		$uq_owner = $owner;
		$uq_owner ~~ s/$domain_pattern[.]$// unless $owner eq '.';
		if ($rrtype eq 'CNAME' && $owner eq $zone) {
		    $message = "Warning: Zone name can not exist as a CNAME";
		    $Load_Status = 3;
		} elsif ($rrtype eq 'NS' && $owner ~~ /^\*(?:[.]|$)/) {
		    $message = "Warning: NS owner name can not exist "
			     . "as a wildcard";
		    $Load_Status = 3;
		} elsif (exists($RRowners{$uq_owner})) {
		    #
		    # See if there's a "CNAME and other data" error.
		    # Allow for the fact that the DNSSEC RRtypes are
		    # are allowed to share owner names with CNAMEs.
		    #
		    $data = $data2 = $RRowners{$uq_owner};
		    if ($rrtype eq 'CNAME') {
			#
			# Remove the DNSSEC RR types from the temporary copy
			# of the accumulated RR types for this owner name.
			# Any leftover RR types will trigger the warning.
			#
			1 while $data2 ~~ s/ (?:$DNSSEC_RRtypes) / /go;
		    }
		    if ($data ~~ / CNAME /
			&& $rrtype !~ /^(?:$DNSSEC_RRtypes)$/o) {
			$message = "Warning: `$uq_owner' already exists "
				 . "as a CNAME";
			$Load_Status = 3;
		    } elsif ($rrtype eq 'CNAME' && $data2 ne " ") {
			$message = "Warning: `$uq_owner' already exists "
				 . "as another resource record";
			$Load_Status = 3;
		    }
		    if ($data !~ / $rrtype /) {
			#
			# If necessary, add the RR type to those
			# already registered to the owner name.
			#
			$RRowners{$uq_owner} .= "$rrtype ";
		    }
		} else {
		    #
		    # Register the new owner name and its RR type.
		    #
		    $RRowners{$uq_owner} = " $rrtype ";
		    #
		    # NOTE: Use the FQDN to make sure that the owner names
		    #       of RRtypes which are subject to stricter name
		    #       checking get passed to CHECK_NAME in their entirety.
		    #
		    $tmp = $owner;
		    if ($rrtype ~~ /^(?:A|MX|WKS)$/) {
			#
			# Make sure to trim the trailing "." and/or any
			# wildcard labels of A, MX, and WKS RRs before
			# submitting the owner field to CHECK_NAME().
			#
			$tmp ~~ s/[.]$//;
			$tmp ~~ s/^\*(?:[.]|$)//;
		    }
		    $error = ($tmp) ?? CHECK_NAME($tmp, $rrtype) !! 0;
		    if ($error) {
			$message .= "Invalid owner name field";
			$Load_Status = $error if $error > $Load_Status;
		    }
		    $data = ($error == 3) ?? "" !! $uq_owner;
		    while ($data ~~ /(?:\\[.]|[^.])*[.]/) {
			#
			# The unqualified owner consists of two or more labels.
			# Register the interior labels in the %RRowners hash
			# so that we can correctly distinguish between a
			# non-existent domain name and a domain name with no
			# DNS resource records during the auditing phase.
			#
			$data ~~ s/(?:\\[.]|[^.])*[.]//;  # strip leading label
			$RRowners{$data} = " " unless exists($RRowners{$data});
		    }
		    if ($rrtype eq 'SRV' && $RFC_2782) {
			#
			# Although the owner fields of SRV RRs are not
			# subject to RFC-1123 name checking, we'll use
			# the presence of another flag, "$RFC_2782", to
			# make sure that the owner field complies with
			# RFC-2782:
			#
			#   1. The Service and Protocol labels are present.
			#   2. Each label begins with an underscore character.
			#
			# BIND does not enforce these specifications, however,
			# since RFC-2915 (the NAPTR RR) requires that the owner
			# field of an SRV RR also exist as an ordinary domain
			# name to which a NAPTR record can point so that a
			# client can obtain the information in the RDATA field
			# of the SRV record.
			#
			# Because of these two possible query contexts, BIND
			# has no other choice than to go with the lowest common
			# denominator and leave the special naming requirements
			# of RFC-2782 unenforced.
			#
			# However, a DNS administrator will presumably know the
			# query context of any SRV RRs in the zone data under
			# his/her control.  Therefore, selective enforcement of
			# RFC-2782 is available via the "$RFC_2782" flag that is
			# set with the -I rfc2782 option.
			#
			if ($owner eq $zone) {
			    $n = ($message) ?? ".\n" !! "";
			    $message .= "${n}Missing SRV Service and Protocol "
				      . "labels";
			} else {
			    ($tmp = $uq_owner) ~~ s/([^\\])[.]/$1 /;
			    ($service, $protocol) = split(' ', $tmp, 2);
			    unless ($service ~~ /^_.+/) {
				$n = ($message) ?? ".\n" !! "";
				$message .= "${n}Leading underscore character "
					  . "missing from SRV Service label";
			    }
			    unless ($protocol) {
				$n = ($message) ?? ".\n" !! "";
				$message .= "${n}Missing SRV Protocol label";
			    } elsif ($protocol !~ /^_.+/) {
				$n = ($message) ?? ".\n" !! "";
				$message .= "${n}Leading underscore character "
					  . "missing from SRV Protocol label";
			    }
			}
		    }
		}
		if ($ttl && $ttl !~ /^(?:\d+|(?:\d+[wdhms])+)$/) {
		    $n = ($message) ?? ".\n" !! "";
		    $message .= "${n}Invalid TTL value";
		    $Load_Status = 3;
		}
		# Parse and process the RDATA field(s) of the various
		# resource record types that will help in the effort
		# to identify the most common types of configuration
		# errors.  Even if the "$Audit" flag is false, the
		# auditing data structures identify new domain names
		# in the RDATA fields and thus help to minimize
		# redundant calls to the CHECK_NAME subroutine.
		# For best efficiency, the processing blocks should be
		# arranged so that the most common RR types appear first.
		# NOTE: In order to conserve memory resources of the
		#       audit-related data structures, domain names are
		#       stored in zone-relative format to the `-d' option
		#       whenever possible.
		#
		1 while $rdata ~~ s/\\\\/\\/g;		# Strip excess escapes.
		$rdata  = $origin    if $rdata eq '@';	# Always fully qualify
		$rdata .= ".$origin" if $rdata !~ /\.$/;# but, if possible, make
		$rdata ~~ s/$domain_pattern[.]$//;	# relative to -d option.
		if ($rrtype eq 'MX') {
		    ($preference, $tmp) = split(' ', $rdata, 2);
		    $rdata = (defined($tmp)) ?? $tmp !! "";
		    if ($preference !~ /^\d+$/ || $preference > 65535) {
			$n = ($message) ?? ".\n" !! "";
			$message .= "${n}Invalid MX Preference value";
			$Load_Status = 3;
		    }
		    if ($rdata ~~ /^\S+$/) {
			if (exists($MXlist{$rdata})) {
			    unless ($MXlist{$rdata} ~~ /$rr_source/) {
				$MXlist{$rdata} .= ", $rr_source";
			    }
			    if ($owner eq $zone) {
				#
				# The reason for checking only the zone apex
				# for redundantly-specified target hostnames
				# of certain routing RRs (MX and RT) is a
				# trade-off.  Complete disclosure could result
				# in the same basic message repeated one or more
				# times for every domain name in a zone plus the
				# memory requirement of storing all the domain
				# names in yet another hash besides %RRowners.
				# Instead, we'll make the reasonably probable
				# assumption that the zone apex has an MX and/or
				# RT RRset that is similar to those throughout
				# the rest of the zone.
				#
				if (exists($Apex_Route_RRs{MX})
				    && exists($Apex_Route_RRs{MX}{$rdata})) {
				    $n = ($message) ?? ".\n" !! "";
				    $message .= "${n}Redundant MX hostname";
				    $Load_Status = 1;
				    $Apex_Route_RRs{MX}{$rdata} .=
								 " $preference";
				} else {
				    $Apex_Route_RRs{MX}{$rdata} = $preference;
				}
			    }
			} else {
			    $MXlist{$rdata} = "$rr_source";
			    if ($owner eq $zone) {
				$Apex_Route_RRs{MX}{$rdata} = $preference;
			    }
			    #
			    # Zone names, i.e., the owner fields of SOA records,
			    # are not subject to RFC-1123 name-checking.  This
			    # is no problem if the zone only contains other
			    # RRtypes which also have less-strict name checking.
			    # For RRtypes which have stricter name checking,
			    # however, make sure the check is contextually
			    # complete by using the FQDN.
			    #
			    $tmp = $rdata;
			    unless ($tmp ~~ /(?:^|[^\\])[.]$/) {
				$tmp .= $zone_suffix
			    }
			    $tmp ~~ s/[.]$//;
			    $error = ($tmp) ?? CHECK_NAME($tmp, 'MX') !! 0;
			    if ($error) {
				$n = ($message) ?? ".\n" !! "";
				$message .= "${n}Invalid MX hostname field";
				$Load_Status = $error if $error > $Load_Status;
			    }
			}
		    } elsif ($rdata) {
			$n = ($message) ?? ".\n" !! "";
			$message .= "${n}Invalid MX hostname field";
			$Load_Status = 3;
		    } else {
			$n = ($message) ?? ".\n" !! "";
			$message .= "${n}Missing MX hostname field";
			$Load_Status = 3;
		    }
		} elsif ($rrtype eq 'A') {
		    #
		    # Verify that an IPv4 address is correctly formatted.
		    #
		    if ($rdata !~ /$IPv4_pattern/o) {
			$n = ($message) ?? ".\n" !! "";
			$message .= "${n}Invalid IPv4 address";
			$Load_Status = 3;
		    }
		} elsif ($rrtype eq 'AAAA') {
		    #
		    # Verify that an IPv6 address is correctly formatted.
		    #
		    if ($rdata !~ /$IPv6_pattern/io) {
			$n = ($message) ?? ".\n" !! "";
			$message .= "${n}Invalid IPv6 address";
			$Load_Status = 3;
		    }
		} elsif ($rrtype eq 'CNAME') {
		    #
		    # Keep track of CNAME references so that dangling
		    # CNAMEs and CNAME loops can be detected.
		    #
		    if ($rdata ~~ /^\S+$/) {
			$rdata_fqdn = $rdata;
			$rdata_fqdn .= ".$origin" unless $rdata_fqdn ~~ /[.]$/;
			if ($rrtype eq 'CNAME' && $uq_owner eq $rdata) {
			    $n = ($message) ?? ".\n" !! "";
			    $message .= "${n}Warning: `$rdata' points back "
				      . "to itself";
			}
			if (exists($Spcl_CNAME{$rdata})) {
			    unless ($Spcl_CNAME{$rdata} ~~ /$rr_source/) {
				$Spcl_CNAME{$rdata} .= ", $rr_source";
			    }
			} else {
			    $error = ($rdata) ?? CHECK_NAME($rdata, 'CNAME') !! 0;
			    if ($error) {
				$n = ($message) ?? ".\n" !! "";
				$message .= "${n}Invalid RDATA field";
				$Load_Status = $error if $error > $Load_Status;
			    }
			    # See if the RDATA domain matches criteria from
			    # the `[-show|hide]-dangling-cnames' option before
			    # registering the domain in the %Spcl_CNAME hash.
			    #
			    $show = $Show_Dangling_CNAMEs;
			    if (@Dangling_CNAME_Domains) {
				foreach $tmp (@Dangling_CNAME_Domains) {
				    next unless $rdata_fqdn ~~ /[.]$tmp[.]$/i;
				    $show = $Dangling_CNAME_Domains{$tmp};
				    last;
				}
			    }
			    $Spcl_CNAME{$rdata} = "$rr_source" if $show;
			}
		    } else {
			$n = ($message) ?? ".\n" !! "";
			$message .= "${n}Invalid RDATA field";
			$Load_Status = 3;
		    }
		} elsif ($rrtype eq 'PTR') {
		    #
		    # Keep track of PTR references to determine whether
		    # or not they properly point to Address RRs.
		    #
		    if ($rdata ~~ /^\S+$/) {
			if (exists($Spcl_PTR{$rdata})) {
			    unless ($Spcl_PTR{$rdata} ~~ /$rr_source/) {
				$Spcl_PTR{$rdata} .= ", $rr_source";
			    }
			} else {
			    $Spcl_PTR{$rdata} = "$rr_source";
			    #
			    # Since the RDATA field must properly point
			    # to a canonical domain name, enforce a
			    # stricter level of checking than was done
			    # on the PTR record's owner field.
			    #
			    $tmp = $rdata;
			    unless ($tmp ~~ /(?:^|[^\\])[.]$/) {
				$tmp .= $zone_suffix;
			    }
			    $tmp ~~ s/[.]$//;
			    $error = ($tmp) ?? CHECK_NAME($tmp, 'A') !! 0;
			    if ($error) {
				$n = ($message) ?? ".\n" !! "";
				$message .= "${n}Invalid RDATA field";
				$Load_Status = $error if $error > $Load_Status;
			    }
			}
		    } else {
			$n = ($message) ?? ".\n" !! "";
			$message .= "${n}Invalid RDATA field";
			$Load_Status = 3;
		    }
		} elsif ($rrtype eq 'RP') {
		    if ($rdata ~~ /^(\S+)\s+(\S+)$/) {
			$rp_mailbox = $1;
			$txt_domain = $2;
			$rp_mailbox = $origin if $rp_mailbox eq '@';
			$txt_domain = $origin if $txt_domain eq '@';
			#
			# Do not append/strip the domain if the
			# MAILBOX/TXTDNAME field ends with/exists as
			# a "." character.
			#
			unless ($rp_mailbox ~~ /(?:^|[^\\])[.]$/) {
			    $rp_mailbox .= $zone_suffix;
			}
			unless ($txt_domain eq ".") {
			    $txt_domain ~~ s/$domain_pattern[.]$//;
			}
			#
			# Starting with BIND 4.9.4, `res_mailok' in `res_comp.c'
			# states that RNAMEs of SOA and RP RRs "can have any
			# printable character in their first label, but the
			# rest of the name has to look like a host name."
			# Also, an RNAME of "." is a valid symbol for a missing
			# representation.  These checks will be made now.
			#
			if ($rp_mailbox ne ".") {
			    $tmp = $rp_mailbox;
			    $tmp ~~ s/(?:\\[.]|[^.])*[.]//;  # strip first label
			    $tmp ~~ s/[.]$//;
			    $error = ($tmp) ?? CHECK_NAME($tmp, 'A') !! 1;
			    if ($error) {
				$n = ($message) ?? ".\n" !! "";
				$message .= "${n}Invalid MAILBOX field "
					  . "in RP RR";
				$Load_Status = $error if $error > $Load_Status;
			    }
			}
			if ($txt_domain ne '.') {
			    if (exists($Spcl_RP{$txt_domain})) {
				unless ($Spcl_RP{$txt_domain} ~~ /$rr_source/) {
				    $Spcl_RP{$txt_domain} .= ", $rr_source";
				}
			    } else {
				$Spcl_RP{$txt_domain} = "$rr_source";
				$error = CHECK_NAME($txt_domain, 'TXT');
				if ($error) {
				    $n = ($message) ?? ".\n" !! "";
				    $message .= "${n}Invalid TXTDNAME field "
					      . "in RP RR";
				    if ($error > $Load_Status) {
					$Load_Status = $error;
				    }
				}
			    }
			}
		    } else {
			$n = ($message) ?? ".\n" !! "";
			$message .= "${n}Invalid number of RDATA fields "
				  . "in RP RR";
			$Load_Status = 3;
		    }
		} elsif ($rrtype eq 'NS' && $owner !~ /^\*(?:[.]|$)/) {
		    if ($rdata ~~ /^\S+$/) {
			if (exists($NSlist{$rdata})) {
			    unless ($NSlist{$rdata} ~~ /$rr_source/) {
				$NSlist{$rdata} .= ", $rr_source";
			    }
			} else {
			    $NSlist{$rdata} = "$rr_source";
			    #
			    # Since the RDATA field must properly point
			    # to a canonical domain name, enforce a
			    # stricter level of checking than was done
			    # on the NS record's owner field.
			    #
			    $tmp = $rdata;
			    unless ($tmp ~~ /(?:^|[^\\])[.]$/) {
				$tmp .= $zone_suffix;
			    }
			    $tmp ~~ s/[.]$//;
			    $error = ($tmp) ?? CHECK_NAME($tmp, 'A') !! 0;
			    if ($error) {
				$n = ($message) ?? ".\n" !! "";
				$message .= "${n}Invalid RDATA field";
				$Load_Status = $error if $error > $Load_Status;
			    }
			}
			if ($Audit) {
			    if ($Verify_Mode && $Recursive_Verify
				&& $owner ne $zone
				&& !exists($NSowners{$uq_owner})) {
				unless (defined($Recursion_Limit) &&
					$Recursion_Depth == $Recursion_Limit) {
				    #
				    # This subzone will be the next one to be
				    # verified unless a subsequent subzone is
				    # encountered.
				    #
				    push(@V_Opt_Domains, $owner,
						    ($Recursion_Depth + 1));
				}
			    }
			    # Store the owner, TTL, and rdata fields of the NS
			    # resource records.  The owner fields will allow
			    # out-of-zone data to be recognized.  The NS RRsets
			    # for each domain will be checked for having at
			    # least two listed name servers (RFC-1034) and
			    # consistent TTL values (RFC-2181).  Checks for
			    # necessary glue records as well as non-glue at or
			    # below any zone cut will also be made.
			    # If we are verifying a domain, the NS records will
			    # be supplied as input data to the `check_del'
			    # program so that proper delegation can be checked.
			    #
			    $NSowners{$uq_owner} .= " " . SECONDS($ttl)
							. " $rdata";
			}
		    } else {
			$n = ($message) ?? ".\n" !! "";
			$message .= "${n}Invalid RDATA field";
			$Load_Status = 3;
		    }
		} elsif ($rrtype eq 'SRV') {
		    ($preference, $weight, $port, $tmp) = split(' ', $rdata, 4);
		    $rdata = (defined($tmp)) ?? $tmp !! "";
		    if ($preference !~ /^\d+$/ || $preference > 65535) {
			$n = ($message) ?? ".\n" !! "";
			$message .= "${n}Invalid SRV Priority value";
			$Load_Status = 3;
		    }
		    if (!defined($weight) || $weight !~ /^\d+$/
			|| $weight > 65535) {
			$n = ($message) ?? ".\n" !! "";
			$tmp = (defined($weight)) ?? "Invalid" !! "Missing";
			$message .= "${n}$tmp SRV Weight value";
			$Load_Status = 3;
		    }
		    if (!defined($port) || $port !~ /^\d+$/ || $port > 65535) {
			$n = ($message) ?? ".\n" !! "";
			$tmp = (defined($port)) ?? "Invalid" !! "Missing";
			$message .= "${n}$tmp SRV Port value";
			$Load_Status = 3;
		    }
		    unless ($rdata) {
			$n = ($message) ?? ".\n" !! "";
			$message .= "${n}Missing SRV Target field";
			$Load_Status = 3;
		    } elsif ($rdata !~ /^\S+$/) {
			$n = ($message) ?? ".\n" !! "";
			$message .= "${n}Invalid SRV Target field";
			$Load_Status = 3;
		    } elsif ($rdata !~ /^[.]$/) {
			if (exists($Spcl_SRV{$rdata})) {
			    unless ($Spcl_SRV{$rdata} ~~ /$rr_source/) {
				$Spcl_SRV{$rdata} .= ", $rr_source";
			    }
			} else {
			    $Spcl_SRV{$rdata} = "$rr_source";
			    #
			    # Since the RDATA field must properly point
			    # to a canonical domain name, enforce a
			    # stricter level of checking than was done
			    # on the NS record's owner field.
			    #
			    $tmp = $rdata;
			    unless ($tmp ~~ /(?:^|[^\\])[.]$/) {
				$tmp .= $zone_suffix;
			    }
			    $tmp ~~ s/[.]$//;
			    $error = ($tmp) ?? CHECK_NAME($tmp, 'A') !! 0;
			    if ($error) {
				$n = ($message) ?? ".\n" !! "";
				$message .= "${n}Invalid SRV Target field";
				$Load_Status = $error if $error > $Load_Status;
			    }
			}
		    }
		} elsif ($rrtype eq 'NSAP') {
		    #
		    # Make sure that the RDATA field meets the
		    # following syntax requirements:
		    #
		    #   * the hexadecimal string begins with "0x" (RFC-1706)
		    #   * optional readability separator is "."
		    #   * hex digits must occur in unseparated pairs
		    #   * at least one pair of hex digits is present
		    #
		    # NOTE: BIND 8.X additionally allows "+" and "/" as
		    #       optional readability separators but BIND 9.X
		    #       does not.  We'll use the BIND 9.X standard.
		    #
		    if ($rdata ~~ /^\S+$/) {
			unless ($rdata ~~ /^0x/i) {
			    $n = ($message) ?? ".\n" !! "";
			    $message .= "${n}RDATA field must begin with "
				      . "`0x' (RFC-1706)";
			    $Load_Status = 3;
			}
			$rdata ~~ s/^0x(?:[.]+)?//i;
			unless ($rdata) {
			    $n = ($message) ?? ".\n" !! "";
			    $message .= "${n}Missing hexadecimal digits "
				      . "in RDATA";
			    $Load_Status = 3;
			} else {
			    $rdata = uc($rdata);
			}
			while (length($rdata)) {
			    ($tmp, $rdata) = split(//, $rdata, 2);
			    next if $tmp eq ".";
			    unless ($tmp ~~ /\d|[A-F]/) {
				$n = ($message) ?? ".\n" !! "";
				$message .= "${n}Invalid character found "
					  . "in RDATA";
				$Load_Status = 3;
				last;
			    }
			    unless ($rdata && $rdata ~~ /^(?:\d|[A-F])/) {
				$n = ($message) ?? ".\n" !! "";
				$message .= "${n}Unpaired hexadecimal digit "
					  . "in RDATA";
				$Load_Status = 3;
				last;
			    } else {
				$rdata ~~ s/^.//;
			    }
			}
		    } else {
			$n = ($message) ?? ".\n" !! "";
			$message .= "${n}Invalid RDATA field";
			$Load_Status = 3;
		    }
		} elsif ($rrtype eq 'AFSDB') {
		    ($preference, $tmp) = split(' ', $rdata, 2);
		    $rdata = (defined($tmp)) ?? $tmp !! "";
		    if ($preference !~ /^\d+$/ || $preference > 65535) {
			$n = ($message) ?? ".\n" !! "";
			$message .= "${n}Invalid AFSDB Subtype value";
			$Load_Status = 3;
		    }
		    if ($rdata ~~ /^\S+$/) {
			if (exists($Spcl_AFSDB{$rdata})) {
			    unless ($Spcl_AFSDB{$rdata} ~~ /$rr_source/) {
				$Spcl_AFSDB{$rdata} .= ", $rr_source";
			    }
			} else {
			    $Spcl_AFSDB{$rdata} = "$rr_source";
			    #
			    # For RRtypes which have stricter name checking,
			    # make sure the check is contextually complete
			    # by using the FQDN.
			    #
			    $tmp = $rdata;
			    unless ($tmp ~~ /(?:^|[^\\])[.]$/) {
				$tmp .= $zone_suffix;
			    }
			    $tmp ~~ s/[.]$//;
			    $error = ($tmp) ?? CHECK_NAME($tmp, 'A') !! 0;
			    if ($error) {
				$n = ($message) ?? ".\n" !! "";
				$message .= "${n}Invalid AFSDB Hostname field";
				$Load_Status = $error if $error > $Load_Status;
			    }
			}
		    } elsif ($rdata) {
			$n = ($message) ?? ".\n" !! "";
			$message .= "${n}Invalid AFSDB Hostname field";
			$Load_Status = 3;
		    } else {
			$n = ($message) ?? ".\n" !! "";
			$message .= "${n}Missing AFSDB Hostname field";
			$Load_Status = 3;
		    }
		} elsif ($rrtype eq 'RT') {
		    ($preference, $tmp) = split(' ', $rdata, 2);
		    $rdata = (defined($tmp)) ?? $tmp !! "";
		    if ($preference !~ /^\d+$/ || $preference > 65535) {
			$n = ($message) ?? ".\n" !! "";
			$message .= "${n}Invalid RT Preference value";
			$Load_Status = 3;
		    }
		    if ($rdata ~~ /^\S+$/) {
			if (exists($Spcl_RT{$rdata})) {
			    unless ($Spcl_RT{$rdata} ~~ /$rr_source/) {
				$Spcl_RT{$rdata} .= ", $rr_source";
			    }
			    if ($owner eq $zone) {
				if (exists($Apex_Route_RRs{RT})
				    && exists($Apex_Route_RRs{RT}{$rdata})) {
				    $n = ($message) ?? ".\n" !! "";
				    $message .= "${n}Redundant RT hostname";
				    $Load_Status = 1;
				    $Apex_Route_RRs{RT}{$rdata} .=
								 " $preference";
				} else {
				    $Apex_Route_RRs{RT}{$rdata} = $preference;
				}
			    }
			} else {
			    $Spcl_RT{$rdata} = "$rr_source";
			    if ($owner eq $zone) {
				$Apex_Route_RRs{RT}{$rdata} = $preference;
			    }
			    #
			    # For RRtypes which have stricter name checking,
			    # make sure the check is contextually complete
			    # by using the FQDN.
			    #
			    $tmp = $rdata;
			    unless ($tmp ~~ /(?:^|[^\\])[.]$/) {
				$tmp .= $zone_suffix;
			    }
			    $tmp ~~ s/[.]$//;
			    $error = ($tmp) ?? CHECK_NAME($tmp, 'A') !! 0;
			    if ($error) {
				$n = ($message) ?? ".\n" !! "";
				$message .= "${n}Invalid RT Intermediate-Host "
					  . "field";
				$Load_Status = $error if $error > $Load_Status;
			    }
			}
		    } elsif ($rdata) {
			$n = ($message) ?? ".\n" !! "";
			$message .= "${n}Invalid RT Intermediate field";
			$Load_Status = 3;
		    } else {
			$n = ($message) ?? ".\n" !! "";
			$message .= "${n}Missing RT Intermediate field";
			$Load_Status = 3;
		    }
		} elsif ($rrtype eq 'SOA') {
		    unless ($Verify_Mode) {
			$n = ($message) ?? ".\n" !! "";
			$message .= "${n}Warning: SOA RR is invalid "
				  . "in the `spcl' file context";
			$Load_Status = 3;
		    } else {
			#
			# "$SOA_Count" is used to detect the duplicate SOA RR
			# that appears at the end of a successful zone transfer.
			# It's also used to prevent the duplicate record from
			# being reprocessed.
			#
			$SOA_Count++;
			if ($SOA_Count > 1) {
			    next if $SOA_Count == 2 && !$message;
			    if ($SOA_Count > 2) {
				$n = ($message) ?? ".\n" !! "";
				$message .= "${n}Warning: found unexpected "
					  . "SOA record";
			    }
			} else {
			    ($RespHost, $RespUser, $serial, $Refresh,
			     $Retry, $Expire, $Ttl) = split(' ', $rdata, 7);
			    $RespHost = $origin if $RespHost eq '@';
			    $RespUser = $origin if $RespUser eq '@';
			    #
			    # Do not append the origin if the MNAME/RNAME
			    # field exists as, or ends with, an unescaped ".".
			    #
			    unless ($RespHost ~~ /(?:^|[^\\])[.]$/) {
				$RespHost .= $zone_suffix;
			    }
			    unless ($RespUser ~~ /(?:^|[^\\])[.]$/) {
				$RespUser .= $zone_suffix;
			    }
			    #
			    # Although a successful zone transfer should return
			    # a valid SOA record, there's a distinct possibility
			    # that it could have bad data (particularly in the
			    # RNAME field) if obtained from a non-BIND server.
			    #
			    if ($owner ne $zone) {
				$n = ($message) ?? ".\n" !! "";
				$message .= "${n}Warning: owner name of "
					  . "SOA RR must match zone name";
			    } elsif ($owner !~ /[.]$/) {
				$n = ($message) ?? ".\n" !! "";
				$message .= "${n}Warning: owner name of "
					  . "SOA RR must be absolute";
			    }
			    if ($RespHost ne ".") {
				$tmp ~~ s/[.]$//;
				if ($tmp && CHECK_NAME($tmp, 'A')) {
				    $n = ($message) ?? ".\n" !! "";
				    $message .= "${n}Invalid MNAME field in "
					      . "SOA RR";
				}
			    }
			    if ($RespUser ne ".") {
				$tmp = $RespUser;
				$tmp ~~ s/(?:\\[.]|[^.])*[.]//;# strip 1st label
				$tmp ~~ s/[.]$//;
				if (!$tmp || CHECK_NAME($tmp, 'A')) {
				    $n = ($message) ?? ".\n" !! "";
				    $message .= "${n}Invalid RNAME field in "
					      . "SOA RR";
				}
			    }
			    if ($serial !~ /^\d+$/ || $serial > 4294967295) {
				$n = ($message) ?? ".\n" !! "";
				$message .= "${n}Invalid Serial number";
			    }
			    unless ($Refresh ~~ /^(?:\d+|(\d+[wdhms])+)$/i) {
				$n = ($message) ?? ".\n" !! "";
				$message .= "${n}Invalid Refresh interval";
				$Valid_SOA_Timers = 0;
			    }
			    unless ($Retry ~~ /^(?:\d+|(\d+[wdhms])+)$/i) {
				$n = ($message) ?? ".\n" !! "";
				$message .= "${n}Invalid Retry interval";
				$Valid_SOA_Timers = 0;
			    }
			    unless ($Expire ~~ /^(?:\d+|(\d+[wdhms])+)$/i) {
				$n = ($message) ?? ".\n" !! "";
				$message .= "${n}Invalid Expiry period";
				$Valid_SOA_Timers = 0;
			    }
			    unless ($Ttl ~~ /^(?:\d+|(\d+[wdhms])+)$/i) {
				$n = ($message) ?? ".\n" !! "";
				$message .= "${n}Invalid default TTL/Negative "
					  . "Cache period";
				$Valid_SOA_Timers = 0;
			    }
			}
		    }
		}
		if ($owner ~~ /^\*(?:[.]..*)?$zone_pattern$/ &&
		    $rrtype !~ /^(?:SOA|NS)$/ && $Audit) {
		    #
		    # Keep track of wildcarded owner names and their
		    # RR types so that nothing is missed when the
		    # AUDIT_RRs subroutine is called.
		    #
		    ($tmp = $owner) ~~ s/^\*[.]//;
		    if (exists($Wildcards{$tmp})) {
			unless ($Wildcards{$tmp} ~~ / $rrtype /) {
			    $Wildcards{$tmp} .= "$rrtype ";
			}
		    } else {
			$Wildcards{$tmp} = " $rrtype ";
		    }
		}
	    } else {
		$message = "Warning: data outside zone `$zone' ignored";
	    }
	} elsif (/^\$INCLUDE(?:$|\s+(\S+)?\s*(\S+)?\s*(\S+)?)/) {
	    $include_file = $1;
	    $new_origin = lc($2);
	    $data = $3;
	    unless ($include_file) {
		$message = "Unable to process \$INCLUDE - filename missing";
		$Load_Status = 3;
	    } else {
		if ($new_origin) {
		    $new_origin = $origin if $new_origin eq "@";
		    unless ($new_origin ~~ /(?:^|[^\\])[.]$/) {
			$new_origin .= $zone_suffix;
		    }
		    $error = ($new_origin) ?? CHECK_NAME($new_origin, 'NS') !! 0;
		    if ($error) {
			$n = ($message) ?? ".\n" !! "";
			$message .= "${n}Domain name in origin argument "
				  . "is invalid";
			$Load_Status = $error if $error > $Load_Status;
		    }
		} else {
		    $new_origin = $origin;
		}
		if ($data) {
		    $n = ($message) ?? ".\n" !! "";
		    $message .= "${n}Found uncommented text in comment field";
		}
		# Stop what we're doing with the current file and make a
		# recursive call to process the specified $INCLUDE file.
		# If the $INCLUDE directive also specified an origin
		# argument, it will be passed along as well.
		# Upon return, we'll automatically revert back to the
		# origin and current owner name that was in effect before
		# the subroutine call.  Restoration of the current owner
		# name is not specifically mentioned in RFC-1035 but is
		# implemented as a feature/deviation in BIND 8 and BIND 9.
		#
		$data = $_;		# $_ is global in scope - save it.
		$warning_status = READ_RRs($include_file, $zone, $new_origin,
					   $owner, $warning_status);
		$_ = $data;
		if ($warning_status == 2) {
		    #
		    # The $INCLUDE filename could not be opened.  An error
		    # message has already been output but without the
		    # terminating newline character.
		    #
		    $message = "\n$message";
		    $warning_status = $Newline_Printed = 1;
		}
	    }
	} elsif (/^\$ORIGIN(?:$|\s+(\S+)?\s*(\S+)?)/) {
	    $new_origin = lc($1);
	    $data = $2;
	    unless ($new_origin) {
		$message = "Missing argument from \$ORIGIN directive";
		$Load_Status = 3;
	    } else {
		if ($new_origin eq '..' && $Verify_Mode) {
		    #
		    # As a hack, get rid of the redundant trailing dot.
		    # DiG version 8.2 erroneously generates this $ORIGIN
		    # directive when it transfers the root zone.
		    #
		    $new_origin = ".";
		}
		$origin = $new_origin unless $new_origin eq "@";
		$origin .= $zone_suffix unless $origin ~~ /(?:^|[^\\])[.]$/;
		$zone_suffix = ($origin eq '.') ?? "." !! ".$origin";
		$error = ($origin) ?? CHECK_NAME($origin, 'NS') !! 0;
		if ($error) {
		    $n = ($message) ?? ".\n" !! "";
		    $message .= "${n}Domain name is invalid";
		    $Load_Status = $error if $error > $Load_Status;
		}
		if ($data) {
		    $n = ($message) ?? ".\n" !! "";
		    $message .= "${n}Found uncommented text in comment field";
		    $Load_Status = 3;
		}
	    }
	} elsif (/^\$TTL(?:$|\s+(\S+)?\s*(\S+)?)/) {
	    $tmp = lc($1);
	    $data = $2;
	    unless ($tmp) {
		$message = "Missing argument from \$TTL directive";
	    } else {
		if ($tmp ~~ /^(?:\d+|(\d+[wdhms])+)$/) {
		    $default_ttl = $tmp;
		} else {
		    $message = "Invalid TTL value - ignored";
		    $Load_Status = 3;
		}
		if ($data) {
		    $n = ($message) ?? ".\n" !! "";
		    $message .= "${n}Found uncommented text in comment field";
		    $Load_Status = 3;
		}
	    }
	} elsif (/^\$(?-i:GENERATE\s+)(?:$|\s*(.*?\s)?($RRtypes)\s+(.*))?/io) {
	    $lhs     = $1;
	    $rrtype = $2;
	    $rdata   = $3;
	    $Gen_Count++;
	    unless ($lhs) {
		$message = "Missing argument(s) in the \$GENERATE directive";
		$Load_Status = 3;
	    } else {
		$lhs ~~ s/\s+$//;
		($range, $lhs, $gen_ttl, $gen_class) = split(' ', $lhs, 4);
		unless (defined($range) && $range ~~ /(\d+)-(\d+)(.*)/) {
		    $message = "Invalid range argument";
		    $Load_Status = 3;
		} else {
		    $start = $1;
		    $stop = $2;
		    $step = $3;
		    if ($stop < $start) {
			$message = "Invalid range (stop < start)";
			$Load_Status = 3;
		    }
		    if ($step) {
			if ($step ~~ /^(.)(\d+)$/) {
			    $data = $1;
			    $step = $2;
			    if ($data ne "/") {
				$n = ($message) ?? ".\n" !! "";
				$message .= "${n}Invalid range argument:"
					  . ' step delimiter must be "/"';
				$Load_Status = 3;
			    }
			} else {
			    $n = ($message) ?? ".\n" !! "";
			    $message .= "${n}Invalid range argument (step)";
			    $Load_Status = 3;
			}
		    } else {
			$step = 1;
		    }
		}
		#
		# As of BIND 9.3.0beta1, the $GENERATE directive supports
		# the inclusion of optional CLASS and/or TTL fields.
		# According to the BIND 9 ARM, this feature will *not* be
		# backported to BIND 8.
		# If either of these optional fields are present *and* if
		# GET_BIND_VERSION() of the master name server (-h option)
		# returns a version number earlier than 9.3.0, return an error.
		#
		unless ($message) {
		    if (defined($gen_ttl) && !defined($gen_class)) {
			#
			# We have three tokens; the already-vetted Range, the
			# assumed LHS template, and a TTL or CLASS token.
			#
			if ($BIND_Version_Num < 90300) {
			    $message = "Unknown extra field preceding the"
				     . " RRtype argument";
			    $Load_Status = 3;
			} elsif ($gen_ttl ~~ /^(?:\d+|(\d+[wdhms])+)$/i) {
			    $gen_class = undef;
			} elsif ($gen_ttl ~~ /^(?:IN|HS|CH(AOS)?|ANY)$/i) {
			    $gen_class = $gen_ttl;
			    $gen_ttl   = undef;
			} else {
			    $message = "Invalid syntax in TTL/CLASS field";
			    $Load_Status = 3;
			}
		    } elsif (defined($gen_ttl) && defined($gen_class)) {
			#
			# We have all four tokens (range, LHS, TTL, and CLASS).
			# Since RFC-1035 permits the optional TTL and CLASS
			# fields to appear in either order, make sure that the
			# appropriate variables are assigned correctly.
			#
			if ($BIND_Version_Num < 90300) {
			    $message = "Unknown extra fields preceding the"
				     . " RRtype argument";
			    $Load_Status = 3;
			} else {
			    if ($gen_ttl ~~ /^(?:IN|HS|CH(AOS)?|ANY)$/i
				&& $gen_class ~~ /^(?:\d+|(\d+[wdhms])+)$/i) {
				#
				# Swap the TTL and CLASS fields.
				#
				$tmp       = $gen_ttl;
				$gen_ttl   = $gen_class;
				$gen_class = $tmp;
			    }
			    if ($gen_ttl !~ /^(?:\d+|(?:\d+[wdhms])+)$/i) {
				$message = "Invalid syntax in TTL field";
				$Load_Status = 3;
			    }
			    if ($gen_class !~ /^(?:IN|HS|CH(?:AOS)?|ANY)$/i) {
				$n = ($message) ?? ".\n" !! "";
				$message = "${n}Invalid syntax in CLASS field";
				$Load_Status = 3;
			    }
			}
		    }
		}
		unless ($message) {
		    $rrtype = uc($rrtype);
		    if ($rrtype !~ /^(?:A|AAAA|CNAME|DNAME|NS|PTR)$/) {
			$message .= "Unsupported RRtype argument";
			$Load_Status = 3;
		    }
		    $rdata ~~ s/\s+$//;
		}
	    }
	    unless ($message) {
		#
		# Now that the basic syntax of the directive has been
		# checked, it's time to register the RRs that BIND
		# will generate into the appropriate global hash(es).
		# This will be done as follows:
		#
		#   1. Loop through the range specification and write
		#      the resulting RRs to a temporary buffer.
		#   2. Take the same action as though an $INCLUDE
		#      directive were encountered - make a recursive
		#      call to READ_RRs to register the RRs into the
		#      appropriate data structure(s).
		#   3. Continue processing the `spcl' file upon return.
		#
		$gen_owner = GEN_NAME($lhs);
		$message = "GEN_NAME: invalid LHS template" unless $gen_owner;
		$gen_rdata = GEN_NAME($rdata);
		unless ($gen_rdata) {
		    unless ($gen_owner) {
			$message = "GEN_NAME: invalid LHS and RHS templates";
		    } else {
			$message = "GEN_NAME: invalid RHS template";
		    }
		}
		if ($Debug) {
		    $gen_file = "$Debug_DIR/h2n-GENERATE_#$Gen_Count";
		    unless (OPEN(*GEN, '>', $gen_file)) {
			$message = "Couldn't open GENERATE debug file: $!";
		    }
		}
		unless ($message) {
		    @gen_buffer = ();
		    push(@gen_buffer, "\$GENERATE directive #$Gen_Count");
		    $data = ($rrtype eq 'PTR') ?? 16 !! 24;
		    if (defined($gen_ttl) || defined($gen_class)) {
			if (defined($gen_ttl)) {
			    $data2 = "$gen_ttl";
			    if (defined($gen_class)) {
				$data2 .= " $gen_class";
			    }
			    $data2 .= "\t";
			} else {
			    $data2 = "$gen_class\t";
			}
		    } else {
			$data2 = "";
		    }
		    for ($i = $start; $i <= $stop; $i += $step) {
			#
			# The eval() function will substitute the current
			# value of "$i" and concatenate any fixed strings
			# in "$gen_owner" and/or "$gen_rdata" to generate
			# RRs with the corresponding owner and RDATA fields.
			#
			$tmp = sprintf("%s\t%s%s\t%s\n",
				       TAB(eval($gen_owner), $data),
				       $data2, $rrtype, eval($gen_rdata));
			push(@gen_buffer, $tmp);
			print GEN $tmp if $Debug;
		    }
		}
		CLOSE(*GEN) if $Debug;
		unless ($message) {
		    #
		    # Make the recursive call that will register the
		    # generated RRs into the relevant data structure(s).
		    #
		    $data = $_;
		    $warning_status = READ_RRs(\@gen_buffer, $zone, $origin,
					       $owner, $warning_status);
		    $_ = $data;
		}
	    }
	} elsif (/^\$/) {
	    $message = "Unknown directive";
	    $Load_Status = 3;
	} else {
	    $message = "Invalid DNS record [unknown RR type and/or "
		     . "missing/extra field(s)] - ignored.\n";
	    $Load_Status = 3;
	}
	if ($message && $Verbose) {
	    if ($Verify_Mode) {
		$message .= "." unless $message ~~ /\n$/;
		$message ~~ s/\n$//;		# prevents double-spaced lines
	    } else {
		$n = ($message ~~ /\n$/) ?? "" !! "; ";
		if (ref($rr_data)) {
		    $message .= "${n}$rr_source";
		} else {
		    $message .= "${n}file $rr_source, line $line_num";
		}
	    }
	    print STDERR "\n" unless $Newline_Printed;
	    $original_line ~~ s/\n$//;		# prevents double-spaced lines
	    if ($rr && $original_line ~~ /^(\S+)?\s+(.+)/s) {
		#
		# Perform some cosmetic data manipulations to
		# ensure the clarity of the diagnostic output.
		#
		$data = $1;
		$tmp = $2;
		if (defined($data)) {
		    $data = ($owner eq $origin) ?? '@' !! $owner;
		    $data ~~ s/$zone_pattern$//;
		} else {
		    $data = "";
		}
		$n = length($data);
		$n = ($n < 24) ?? 24 !! $n;
		printf STDERR "%s\n%s%s\n", $message, TAB("> $data", $n), $tmp;
	    } else {
		print STDERR "$message\n> $original_line\n";
	    }
	    $message = $n = "";
	    $warning_status = $Newline_Printed = 1;
	}
    }
    CLOSE(*FILE) unless ref($rr_data);
    if ($open_quote || $open_paren_count) {
	if (!ref($rr_data) && $Verbose) {
	    $char = ($open_quote) ?? "quotes" !! "parentheses";
	    print STDERR "Unable to process file `$rr_data'\n",
			 "due to unbalanced $char.  The syntax ",
			 "problem begins at line $split_line_num.\n";
	    $warning_status = $Newline_Printed = 1;
	}
	$Load_Status = 4;
    }
    return $warning_status;
}



#
# Subroutine to determine if a domain name is part of
# a child domain or matches a wildcard owner name.
#
# Return value:
#   ($subzone, $wildcard, $wildcard_rrtypes)
#
#   The null string is returned for any list element which
#   does not have a matching value.
#
sub MATCH_DOMAIN {
    my ($domain_name) = @_;
    my ($subzone, $uq_domain_name, $wildcard);
    my ($wildcard_matching_ok, $wildcard_rrtypes);

    # There are two basic approaches for seeing if a domain
    # name matches a child zone or wildcard:
    #
    #  1. Fetch child zones/wildcards from their respective
    #     hashes until a match is found or there are no more
    #     hash indices to compare.  This is a classic example
    #     of an N**2 search algorithm which becomes very slow
    #     for a zone with many child zones and/or wildcards.
    #
    #  2. [a] See if the current domain name matches that
    #         of a child zone/wildcard.
    #     [b] If no match is found, strip the first label
    #         from the current domain name and retry step [a]
    #         until either a match is found or the remaining
    #         label(s) match the current zone being audited.
    #
    # The cumulative search time for the second method has a linear
    # relationship to the number of child zones/wildcards and, thus,
    # is implemented here.
    #
    $subzone = $wildcard = $wildcard_rrtypes = "";
    $wildcard_matching_ok = 1;
    #
    # NOTE: The "$domain_name" parameter as well as the global variables
    #       "$Domain" and "$Domain_Pattern" have already been lower-cased
    #       by AUDIT_RRs(), the sole caller of this subroutine.
    #
    while ($domain_name && ".$domain_name" ~~ /$Domain_Pattern[.]$/) {
	($uq_domain_name = $domain_name) ~~ s/$Domain_Pattern[.]$//;
	#
	# The following test will be made for each label of the passed
	# domain name until either a subzone is matched or the current
	# zone apex is reached.  Even if a wildcard is ostensibly matched
	# in the subsequent block, we need to keep testing for a subzone
	# since delegation cancels wildcard matching.
	#
        if ($domain_name ne "$Domain." && exists($NSowners{$uq_domain_name})) {
	    $subzone = $domain_name;
	    #
	    # Per RFC-1034, the wildcard matching algorithm does not apply
	    # across zone boundaries, i.e., delegation cancels the wildcard
	    # defaults.  Make sure to nullify any such previous match.
	    #
	    $wildcard = $wildcard_rrtypes = "" if $wildcard;
	    last;
	}
	if ($wildcard_matching_ok) {
	    #
	    # The following wildcard tests will be made for each label
	    # of the passed domain name until one of the following
	    # conditions is met:
	    #
	    #   1. A DNS node (either empty or owning one or more RRs)
	    #      exists at or between the passed domain name and an
	    #      otherwise-matching wildcard.
	    #
	    #   2. A wildcard is matched.  This keeps the longest match in
	    #      case another wildcard with fewer labels would otherwise
	    #      match as well.
	    #
	    #   3. A subzone is matched.  This cancels any previous wildcard
	    #      match.
	    #
	    #   4. The label(s) representing the current zone apex is/are
	    #      reached.
	    #
	    if ($uq_domain_name ne $domain_name
		&& exists($RRowners{$uq_domain_name})) {
		#
		# If the passed domain name explicitly matches a DNS node
		# (empty or having any resource record) or a DNS node is
		# known to exist in the DNS hierarchy between the passed
		# domain name and the nearest intra-zone wildcard, a
		# wildcard match must not occur according to RFC-1034.
		# For example, given the following RRs:
		#
		#   foo.example.com.      A      192.168.1.1
		#   foo.moo.example.com.  A      192.168.2.2
		#   *.example.com.        MX     10 foo.example.com.
		#   zoo.example.com.      CNAME  zoo.foo.example.com.
		#   goo.example.com.      CNAME  fee.fie.example.com.
		#
		# the resolution of `zoo.foo.example.com' would be
		# NXDOMAIN since `foo.example.com' exists as a node
		# in the DNS namespace (it also happens to be an owner
		# of an RR) and does not have a wildcard.  NXDOMAIN
		# would also be returned for `zoo.moo.example.com'
		# since `moo.example.com' exists as a DNS node even
		# though that domain name does not own any records.
		# The domain `fee.fie.example.com', on the other hand,
		# does match the wildcard since there is no explicit
		# match for that owner name nor for `fie.example.com'.
		# However, if the following record were added:
		#
		#   *.foo.example.com.    A      192.168.3.3
		#
		# then `zoo.foo.example.com' would match this more
		# explicit wildcard.
		#
		$wildcard_matching_ok = 0 if !exists($Wildcards{$domain_name});
	    }
	    if ($wildcard_matching_ok && exists($Wildcards{$domain_name})) {
		#
		# The longest-matching wildcard (may be multi-label) has
		# been found.  Once stored into the "$wildcard" variable,
		# further wildcard matching attempts are cancelled.
		# We will not exit the label-trimming loop, however,
		# because the RFC-1034 wildcard algorithm requires us
		# to continue searching for a matching subzone which
		# will cancel this wildcard match.
		#
		$wildcard = "*.$domain_name";
		$wildcard_rrtypes = $Wildcards{$domain_name};
		$wildcard_matching_ok = 0;
	    }
	}
	# Find the leading label, i.e., the characters up to
	# and including the first unescaped ".", and remove
	# it from the domain name prior to the next attempt
	# at matching a child domain/wildcard.
	#
	$domain_name ~~ s/(?:\\[.]|[^.])*[.]//;
    }
    return ($subzone, $wildcard, $wildcard_rrtypes);
}


#
# Perform some final error checking that is only possible after
# all of this zone's data has been accounted for.
# Checks are made for the following conditions:
#   * NS, MX, PTR, SRV, RT, and AFSDB records that point to CNAMEs or
#     domain names with no Address records or to nonexistent domains.
#   * RP records with TXTDNAME fields that reference nonexistent
#     TXT records.
#   * CNAME records that point to nonexistent domain names, i.e.,
#     "dangling" CNAMEs.
#   * Zones with only one listed name server (violates RFC-1034),
#     NS RRsets with inconsistent TTL values (violates RFC-2181),
#     NS RRs with missing glue records, and non-glue records at
#     or below a zone cut.
# This subroutine assumes that the `DiG' program is available for
# resolving domain names that are external to the zone being processed.
#
# Having these checks performed by `h2n' after it builds the zone
# data files is useful because such misconfigurations are not reported
# in the syslog when the zone is initially loaded by `named'.  To do so
# would require `named' to make two passes though the data, an impractical
# task to add to its overhead.  Even though `named' eventually logs these
# domain names when they are accessed, it's also impractical to expect
# busy hostmasters to be constantly scanning the syslog(s) for such events.
#
# NOTE: Since this subroutine could be called for every run of `h2n'
#       that processes a host file, careful consideration should be made
#       before adding any more data verification tasks.  Additional data
#       checks which are time-consuming and/or esoteric may be better
#       placed in the "CHECK_ZONE" subroutine and called with the
#       -V option instead.
#
# Return values:
#   0 = no warnings
#   1 = warnings
#
sub AUDIT_RRs {
    my ($warning_status) = @_;
    my ($additional, $answer, $authority, $buffer, $chain_length);
    my ($chained_subzone, $cname, $cname_loop, $cname_n, $debug_file);
    my ($dig_batch, $flags, $first_answer, $fq_host, $glue_found);
    my ($glue_missing, $glue_over_limit, $glue_problem, $glueless_depth);
    my ($host, $i, $k, $last_zone, $location, $match, $max_chain_length);
    my ($n, $nextbatch, $nextbatch_is_open, $ns_count, $ns_host, $ns_list);
    my ($ns_subzone, $query_options, $query_section, $result, $rrtype);
    my ($saved_cname, $status, $subzone, $subzones_exist, $t, $tmp, $ttl);
    my ($warning, $wildcard, $wildcards_exist, $zone);
    my (%already_queued, %already_seen, %base_cname, %chain_cname);
    my (%ext_afsdb, %ext_cname, %ext_mx, %ext_ptr, %ext_rp, %ext_rt);
    my (%ext_srv, %glue_rr, %non_glue_rr);
    my (@ns_rfc_1034, @ns_rfc_2181, @delete_list, @msg_buf);
    my (@subzone_queue, @temp);

    $n = ($warning_status) ?? "" !! "\n";	# controls output of cosmetic newlines
    if ($Verify_Mode) {			# other cosmetic considerations
	$t = 40;
	$location = "(SOA MNAME)";
    } else {
	$t = 32;
	$location = "-h option";
    }
    $Domain = lc($Domain);			  # if -P option is in effect
    $Domain_Pattern = lc($Domain_Pattern);	  # ditto
    $Audit_Domain = ($Domain) ?? "$Domain." !! "";  # accommodate the root zone
    #
    # Add the master name server in the `-h' option or, if in verify mode,
    # the name server from the SOA MNAME field, to the list of any name
    # servers found in the READ_RRs subroutine.
    #
    unless ($RespHost ~~ /^[.]?$/) {
	($host = lc($RespHost)) ~~ s/$Domain_Pattern[.]$//;
	if (exists($NSlist{$host})) {
	    $NSlist{$host} = "$location, $NSlist{$host}";
	} else {
	    $NSlist{$host} = $location;
	}
    }
    unless ($Verify_Mode) {
	#
	# Add the name servers from the `-s' and `-S' options to the data
	# set of other name servers that may have found when reading a
	# `spcl' file.  Similarly, mailhosts from any `-m' options will
	# be added to any `spcl' mailhosts.
	#
	foreach $host (@Full_Servers) {
	    ($host = lc($host)) ~~ s/$Domain_Pattern[.]$//o;
	    if (exists($NSlist{$host})) {
		$location = $NSlist{$host};
		if ($location ~~ /-h option/) {
		    $location ~~ s/-h option/-h,-s options/;
		} elsif ($location !~ /-s option/) {
		    $location = "-s option, $location";
		}
		$NSlist{$host} = $location;
	    } else {
		$NSlist{$host} = "-s option";
	    }
	    # Register the NS RRs of this domain in the same manner
	    # as any child domains that were found in a `spcl' file.
	    #
	    $NSowners{"$Domain."} .= " " . SECONDS($DefTtl) . " $host";
	}
	foreach $tmp (keys %Partial_Servers) {
	    @temp = split(' ', $Partial_Servers{$tmp});
	    foreach $host (@temp) {
		($host = lc($host)) ~~ s/$Domain_Pattern[.]$//o;
		if (exists($NSlist{$host})) {
		    $location = $NSlist{$host};
		    if ($location ~~ /-[hs] option/) {
			$location ~~ s/([^ ]+) options?/$1,-S options/;
		    } elsif ($location !~ /-S option/) {
			$location = "-S option, $location";
		    }
		    $NSlist{$host} = $location;
		} else {
		    $NSlist{$host} = "-S option";
		}
		# Register the NS RRs of the forward-mapping domain.
		#
		$NSowners{"$Domain."} .= " " . SECONDS($DefTtl)
					     . " $host" if $tmp eq $Domainfile;
	    }
	}

	if ($Do_MX || $Do_Zone_Apex_MX) {
	    #
	    # Combine the `-m' and `spcl' MX data structures into one.
	    # The %MXlist hash will track each mailhost and where it was found.
	    # NOTE: In-zone hostnames in the @MX array are already stored
	    #       as UQDNs.
	    #
	    foreach $buffer (@MX) {
		($tmp, $host) = split(' ', $buffer, 2);
		$host = ($host eq '@') ?? "$Domain." !! lc($host);
		if (exists($MXlist{$host})) {
		    $location = $MXlist{$host};
		    if ($location ~~ /^-T option/) {
			$location ~~ s/-T option/-T,-m options/;
		    } elsif ($location !~ /-m option/) {
			$location = "-m option, $location";
		    }
		    $MXlist{$host} = $location;
		} else {
		    $MXlist{$host} = "-m option";
		}
	    }
	}
    }

    # Undefine data structures that are no longer needed so that
    # the "%ext*" hashes have the maximum amount of room to grow
    # as each RR type is audited.
    #
    undef @Full_Servers;
    undef %Partial_Servers;
    undef @MX;
    undef @temp;

    $subzones_exist = keys(%NSowners);
    $wildcards_exist = keys(%Wildcards);
    scalar(keys(%NSlist));			# Reset the iterator!
    while (($host, $location) = each %NSlist) {
	#
	# Try to find an explicit match in the local domain.
	#
	if ($host !~ /[^\\][.]$/ || $host eq "$Domain.") {
	    $match = $warning = 0;
	    if (exists($Hosts{$host})) {
		$match = 1;
	    } elsif (exists($RRowners{$host})) {
		$rrtype = $RRowners{$host};
		if ($rrtype ~~ / (?:A|AAAA) /) {
		    $match = 1;
		} elsif ($rrtype ~~ / CNAME /) {
		    $match = $warning = 1;
		    $NSlist{$host} = "[CNAME record]|$NSlist{$host}";
		} elsif ($rrtype eq " ") {
		    $match = $warning = 1;
		    $NSlist{$host} = "[ empty node ]|$NSlist{$host}";
		} else {
		    $match = $warning = 1;
		    $NSlist{$host} = "[no A(AAA) RR]|$NSlist{$host}";
		}
	    }
	    if ($subzones_exist || (!$match && $wildcards_exist)) {
		#
		# If no explicit match was found, try matching an existing
		# wildcard.  In any case, however, see if the domain name of
		# this NS host belongs to a delegated subdomain.  If so, the
		# `DiG' program will be called upon to make sure that the
		# domain name can be resolved.
		#
		$fq_host = ($host eq "$Domain.") ?? $host
						 !! "$host.$Audit_Domain";
		($subzone, $wildcard, $rrtype) = MATCH_DOMAIN($fq_host);
		if ($subzone) {
		    $match = 1;
		    $warning = 0;
		    $Ext_NS{$fq_host} = $location if $Query_External_Domains;
		} elsif (!$match && $wildcard) {
		    $match = 1;
		    unless ($rrtype ~~ / (?:A|AAAA) /) {
			if ($rrtype ~~ / CNAME /) {
			    $warning = "(*) CNAME RR";
			} elsif ($rrtype ~~ / MX /) {
			    $warning = " (*) MX RR  ";
			} else {
			    $warning = "(*) non-A RR";
			}
			$NSlist{$host} = "[$warning]|$NSlist{$host}";
		    }
		}
	    }
	    if ($match) {
		push(@delete_list, $host) unless $warning;
	    } else {
		$NSlist{$host} = "[no such name]|$NSlist{$host}";
	    }
	} else {
	    #
	    # Save the external NS host for `DiG' to look up later.
	    #
	    $Ext_NS{$host} = $location if $Query_External_Domains;
	    push(@delete_list, $host);
	}
    }
    # Now that we're no longer iterating over %NSlist, remove
    # the hash keys that were marked for deletion.
    #
    foreach $host (@delete_list) {
	delete($NSlist{$host});
    }

    @delete_list = ();
    scalar(keys(%MXlist));
    while (($host, $location) = each %MXlist) {
	if ($host !~ /[^\\][.]$/ || $host eq "$Domain.") {
	    $match = $warning = 0;
	    if (exists($Hosts{$host})) {
		$match = 1;
	    } elsif (exists($RRowners{$host})) {
		$rrtype = $RRowners{$host};
		if ($rrtype ~~ / (?:A|AAAA) /) {
		    $match = 1;
		} elsif ($rrtype ~~ / CNAME /) {
		    $match = $warning = 1;
		    $MXlist{$host} = "[CNAME record]|$MXlist{$host}";
		} elsif ($rrtype eq " ") {
		    $match = $warning = 1;
		    $MXlist{$host} = "[ empty node ]|$MXlist{$host}";
		} else {
		    $match = $warning = 1;
		    $MXlist{$host} = "[no A(AAA) RR]|$MXlist{$host}";
		}
	    }
	    if ($subzones_exist || (!$match && $wildcards_exist)) {
		$fq_host = ($host eq "$Domain.") ?? $host
						 !! "$host.$Audit_Domain";
		($subzone, $wildcard, $rrtype) = MATCH_DOMAIN($fq_host);
		if ($subzone) {
		    $match = 1;
		    $warning = 0;
		    $ext_mx{$fq_host} = $location if $Query_External_Domains;
		} elsif (!$match && $wildcard) {
		    $match = 1;
		    unless ($rrtype ~~ / (?:A|AAAA) /) {
			if ($rrtype ~~ / CNAME /) {
			    $warning = "(*) CNAME RR";
			} elsif ($rrtype ~~ / MX /) {
			    $warning = " (*) MX RR  ";
			} else {
			    $warning = "(*) non-A RR";
			}
			$MXlist{$host} = "[$warning]|$MXlist{$host}";
		    }
		}
	    }
	    if ($match) {
		push(@delete_list, $host) unless $warning;
	    } else {
		$MXlist{$host} = "[no such name]|$MXlist{$host}";
	    }
	} else {
	    $ext_mx{$host} = $location if $Query_External_Domains;
	    push(@delete_list, $host);
	}
    }
    foreach $host (@delete_list) {
	delete($MXlist{$host});
    }

    # Attempt to reconcile the Target domain name of any SRV RRs
    # that were found while scanning a `spcl' or zone data file.
    #
    @delete_list = ();
    scalar(keys(%Spcl_SRV));
    while (($host, $location) = each %Spcl_SRV) {
	if ($host !~ /[^\\][.]$/ || $host eq "$Domain.") {
	    $match = $warning = 0;
	    if (exists($Hosts{$host})) {
		$match = 1;
	    } elsif (exists($RRowners{$host})) {
		$rrtype = $RRowners{$host};
		if ($rrtype ~~ / (?:A|AAAA) /) {
		    $match = 1;
		} elsif ($rrtype ~~ / CNAME /) {
		    $match = $warning = 1;
		    $Spcl_SRV{$host} = "[CNAME record]|$Spcl_SRV{$host}";
		} elsif ($rrtype eq " ") {
		    $match = $warning = 1;
		    $Spcl_SRV{$host} = "[ empty node ]|$Spcl_SRV{$host}";
		} else {
		    $match = $warning = 1;
		    $Spcl_SRV{$host} = "[no A(AAA) RR]|$Spcl_SRV{$host}";
		}
	    }
	    if ($subzones_exist || (!$match && $wildcards_exist)) {
		$fq_host = ($host eq "$Domain.") ?? $host
						 !! "$host.$Audit_Domain";
		($subzone, $wildcard, $rrtype) = MATCH_DOMAIN($fq_host);
		if ($subzone) {
		    $match = 1;
		    $warning = 0;
		    $ext_srv{$fq_host} = $location if $Query_External_Domains;
		} elsif (!$match && $wildcard) {
		    $match = 1;
		    unless ($rrtype ~~ / (?:A|AAAA) /) {
			if ($rrtype ~~ / CNAME /) {
			    $warning = "(*) CNAME RR";
			} elsif ($rrtype ~~ / MX /) {
			    $warning = " (*) MX RR  ";
			} else {
			    $warning = "(*) non-A RR";
			}
			$Spcl_SRV{$host} = "[$warning]|$Spcl_SRV{$host}";
		    }
		}
	    }
	    if ($match) {
		push(@delete_list, $host) unless $warning;
	    } else {
		$Spcl_SRV{$host} = "[no such name]|$Spcl_SRV{$host}";
	    }
	} else {
	    $ext_srv{$host} = $location if $Query_External_Domains;
	    push(@delete_list, $host);
	}
    }
    foreach $host (@delete_list) {
	delete($Spcl_SRV{$host});
    }

    # Attempt to reconcile the RDATA field of any PTR RRs that
    # were found while scanning a `spcl' or zone data file.
    #
    @delete_list = ();
    scalar(keys(%Spcl_PTR));
    while (($host, $location) = each %Spcl_PTR) {
	if ($host !~ /[^\\][.]$/ || $host eq "$Domain.") {
	    $match = $warning = 0;
	    if (exists($Hosts{$host})) {
		$match = 1;
	    } elsif (exists($RRowners{$host})) {
		$rrtype = $RRowners{$host};
		if ($rrtype ~~ / (?:A|AAAA|NSAP) /) {
		    $match = 1;
		} elsif ($rrtype ~~ / CNAME /) {
		    $match = $warning = 1;
		    $Spcl_PTR{$host} = "[CNAME record]|$Spcl_PTR{$host}";
		} elsif ($rrtype eq " ") {
		    $match = $warning = 1;
		    $Spcl_PTR{$host} = "[ empty node ]|$Spcl_PTR{$host}";
		} else {
		    $match = $warning = 1;
		    $Spcl_PTR{$host} = "[no A(AAA) RR]|$Spcl_PTR{$host}";
		}
	    }
	    if ($subzones_exist || (!$match && $wildcards_exist)) {
		$fq_host = ($host eq "$Domain.") ?? $host
						 !! "$host.$Audit_Domain";
		($subzone, $wildcard, $rrtype) = MATCH_DOMAIN($fq_host);
		if ($subzone) {
		    $match = 1;
		    $warning = 0;
		    $ext_ptr{$fq_host} = $location if $Query_External_Domains;
		} elsif (!$match && $wildcard) {
		    $match = 1;
		    unless ($rrtype ~~ / (?:A|AAAA|NSAP) /) {
			if ($rrtype ~~ / CNAME /) {
			    $warning = "(*) CNAME RR";
			} elsif ($rrtype ~~ / MX /) {
			    $warning = " (*) MX RR  ";
			} else {
			    $warning = "(*) non-A RR";
			}
			$Spcl_PTR{$host} = "[$warning]|$Spcl_PTR{$host}";
		    }
		}
	    }
	    if ($match) {
		push(@delete_list, $host) unless $warning;
	    } else {
		$Spcl_PTR{$host} = "[no such name]|$Spcl_PTR{$host}";
	    }
	} else {
	    $ext_ptr{$host} = $location if $Query_External_Domains;
	    push(@delete_list, $host);
	}
    }
    foreach $host (@delete_list) {
	delete($Spcl_PTR{$host});
    }

    # Attempt to reconcile the HOSTNAME field of any AFSDB RRs that
    # were found while scanning a `spcl' or zone data file.
    #
    @delete_list = ();
    scalar(keys(%Spcl_AFSDB));
    while (($host, $location) = each %Spcl_AFSDB) {
	if ($host !~ /[^\\][.]$/ || $host eq "$Domain.") {
	    $match = $warning = 0;
	    if (exists($Hosts{$host})) {
		$match = 1;
	    } elsif (exists($RRowners{$host})) {
		$rrtype = $RRowners{$host};
		if ($rrtype ~~ / (?:A|AAAA) /) {
		    $match = 1;
		} elsif ($rrtype ~~ / CNAME /) {
		    $match = $warning = 1;
		    $Spcl_AFSDB{$host} = "[CNAME record]|$Spcl_AFSDB{$host}";
		} elsif ($rrtype eq " ") {
		    $match = $warning = 1;
		    $Spcl_AFSDB{$host} = "[ empty node ]|$Spcl_AFSDB{$host}";
		} else {
		    $match = $warning = 1;
		    $Spcl_AFSDB{$host} = "[no A(AAA) RR]|$Spcl_AFSDB{$host}";
		}
	    }
	    if ($subzones_exist || (!$match && $wildcards_exist)) {
		$fq_host = ($host eq "$Domain.") ?? $host
						 !! "$host.$Audit_Domain";
		($subzone, $wildcard, $rrtype) = MATCH_DOMAIN($fq_host);
		if ($subzone) {
		    $match = 1;
		    $warning = 0;
		    $ext_afsdb{$fq_host} = $location if $Query_External_Domains;
		} elsif (!$match && $wildcard) {
		    $match = 1;
		    unless ($rrtype ~~ / (?:A|AAAA) /) {
			if ($rrtype ~~ / CNAME /) {
			    $warning = "(*) CNAME RR";
			} elsif ($rrtype ~~ / MX /) {
			    $warning = " (*) MX RR  ";
			} else {
			    $warning = "(*) non-A RR";
			}
			$Spcl_AFSDB{$host} = "[$warning]|$Spcl_AFSDB{$host}";
		    }
		}
	    }
	    if ($match) {
		push(@delete_list, $host) unless $warning;
	    } else {
		$Spcl_AFSDB{$host} = "[no such name]|$Spcl_AFSDB{$host}";
	    }
	} else {
	    $ext_afsdb{$host} = $location if $Query_External_Domains;
	    push(@delete_list, $host);
	}
    }
    foreach $host (@delete_list) {
	delete($Spcl_AFSDB{$host});
    }

    # Attempt to reconcile the INTERMEDIATE-HOST field of any RT RRs
    # that were found while scanning a `spcl' or zone data file.
    #
    @delete_list = ();
    scalar(keys(%Spcl_RT));
    while (($host, $location) = each %Spcl_RT) {
	if ($host !~ /[^\\][.]$/ || $host eq "$Domain.") {
	    $match = $warning = 0;
	    if (exists($Hosts{$host})) {
		$match = 1;
	    } elsif (exists($RRowners{$host})) {
		$rrtype = $RRowners{$host};
		if ($rrtype ~~ / (?:A|AAAA|ISDN|X25) /) {
		    $match = 1;
		} elsif ($rrtype ~~ / CNAME /) {
		    $match = $warning = 1;
		    $Spcl_RT{$host} = "[CNAME record]|$Spcl_RT{$host}";
		} elsif ($rrtype eq " ") {
		    $match = $warning = 1;
		    $Spcl_RT{$host} = "[ empty node ]|$Spcl_RT{$host}";
		} else {
		    $match = $warning = 1;
		    $Spcl_RT{$host} = "[no A(AAA) RR]|$Spcl_RT{$host}";
		}
	    }
	    if ($subzones_exist || (!$match && $wildcards_exist)) {
		$fq_host = ($host eq "$Domain.") ?? $host
						 !! "$host.$Audit_Domain";
		($subzone, $wildcard, $rrtype) = MATCH_DOMAIN($fq_host);
		if ($subzone) {
		    $match = 1;
		    $warning = 0;
		    $ext_rt{$fq_host} = $location if $Query_External_Domains;
		} elsif (!$match && $wildcard) {
		    $match = 1;
		    unless ($rrtype ~~ / (?:A|AAAA|ISDN|X25) /) {
			if ($rrtype ~~ / CNAME /) {
			    $warning = "(*) CNAME RR";
			} elsif ($rrtype ~~ / MX /) {
			    $warning = " (*) MX RR  ";
			} else {
			    $warning = "(*) non-A RR";
			}
			$Spcl_RT{$host} = "[$warning]|$Spcl_RT{$host}";
		    }
		}
	    }
	    if ($match) {
		push(@delete_list, $host) unless $warning;
	    } else {
		$Spcl_RT{$host} = "[no such name]|$Spcl_RT{$host}";
	    }
	} else {
	    $ext_rt{$host} = $location if $Query_External_Domains;
	    push(@delete_list, $host);
	}
    }
    foreach $host (@delete_list) {
	delete($Spcl_RT{$host});
    }

    # Attempt to reconcile the TXTDNAME field of any RP RRs that
    # were found while scanning a `spcl' or zone data file.
    #
    @delete_list = ();
    scalar(keys(%Spcl_RP));
    while (($host, $location) = each %Spcl_RP) {
	if ($host !~ /[^\\][.]$/ || $host eq "$Domain.") {
	    $match = $warning = 0;
	    if (exists($RRowners{$host})) {
		$rrtype = $RRowners{$host};
		if ($rrtype ~~ / TXT /) {
		    $match = 1;
		} elsif ($rrtype ~~ / CNAME /) {
		    $match = $warning = 1;
		    $Spcl_RP{$host} = "[CNAME record]|$Spcl_RP{$host}";
		} elsif ($rrtype eq " ") {
		    $match = $warning = 1;
		    $Spcl_RP{$host} = "[no RRs exist]|$Spcl_RP{$host}";
		} else {
		    $match = $warning = 1;
		    $Spcl_RP{$host} = "[ no TXT RR  ]|$Spcl_RP{$host}";
		}
	    }
	    if ($subzones_exist || (!$match && $wildcards_exist)) {
		$fq_host = ($host eq "$Domain.") ?? $host
						 !! "$host.$Audit_Domain";
		($subzone, $wildcard, $rrtype) = MATCH_DOMAIN($fq_host);
		if ($subzone) {
		    $match = 1;
		    $warning = 0;
		    $ext_rp{$fq_host} = $location if $Query_External_Domains;
		} elsif (!$match && $wildcard) {
		    $match = 1;
		    unless ($rrtype ~~ / TXT /) {
			if ($rrtype ~~ / CNAME /) {
			    $warning = "(*) CNAME RR";
			} elsif ($rrtype ~~ / MX /) {
			    $warning = " (*) MX RR  ";
			} else {
			    $warning = "(*)nonTXT RR";
			}
			$Spcl_RP{$host} = "[$warning]|$Spcl_RP{$host}";
		    }
		}
	    }
	    if ($match) {
		push(@delete_list, $host) unless $warning;
	    } else {
		$Spcl_RP{$host} = "[no such name]|$Spcl_RP{$host}";
	    }
	} else {
	    $ext_rp{$host} = $location if $Query_External_Domains;
	    push(@delete_list, $host);
	}
    }
    foreach $host (@delete_list) {
	delete($Spcl_RP{$host});
    }

    # Attempt to reconcile the RDATA field of any CNAMEs that
    # were found while scanning a `spcl' or zone data file.
    #
    @delete_list = ();
    scalar(keys(%Spcl_CNAME));
    while (($host, $location) = each %Spcl_CNAME) {
	if ($host !~ /[^\\][.]$/ || $host eq "$Domain.") {
	    $match = $warning = 0;
	    if (exists($Hosts{$host})) {
		$match = 1;
	    } elsif (exists($RRowners{$host})) {
		$match = 1;
		if ($RRowners{$host} eq " ") {
		    $warning = 1;
		    $Spcl_CNAME{$host} = "[no RRs exist]|$Spcl_CNAME{$host}";
		}
	    }
	    if ($subzones_exist || (!$match && $wildcards_exist)) {
		$fq_host = ($host eq "$Domain.") ?? $host
						 !! "$host.$Audit_Domain";
		($subzone, $wildcard, $rrtype) = MATCH_DOMAIN($fq_host);
		if ($subzone) {
		    $match = 1;
		    $ext_cname{$fq_host} = $location if $Query_External_Domains;
		} elsif (!$match && $wildcard) {
		    $match = 1;
		}
	    }
	    if ($match) {
		push(@delete_list, $host) unless $warning;
	    } else {
		$Spcl_CNAME{$host} = "[no such name]|$Spcl_CNAME{$host}";
	    }
	} else {
	    $ext_cname{$host} = $location if $Query_External_Domains;
	    push(@delete_list, $host);
	}
    }
    foreach $host (@delete_list) {
	delete($Spcl_CNAME{$host});
    }

    $answer = keys(%Ext_NS) + keys(%ext_mx) + keys(%ext_srv) + keys(%ext_ptr)
	      + keys(%ext_afsdb) + keys(%ext_rt) + keys(%ext_rp)
	      + keys(%ext_cname);
    if ($answer) {
	#
	# Use `DiG' to to find out if the external domain names refer
	# to CNAMEs, lack Address records, or if they even exist.
	#
	$i = "00";
	$chain_length = $max_chain_length = 0;
	$dig_batch = "$Debug_DIR/h2n-dig.bat${i}_$Data_Fname";
	unless (open(*DIGBATCH, '>', $dig_batch)) {
	    print STDERR "Couldn't create batch file for `DiG': $!\n",
			 "Unable to check external domain names.\n";
	    %Ext_NS = %ext_mx = %ext_ptr = %ext_rp = %ext_cname = ();
	} else {
	    while (($host, $tmp) = each %Ext_NS) {
		print DIGBATCH "$host A \%NS\n";
	    }
	    while (($host, $tmp) = each %ext_mx) {
		print DIGBATCH "$host A \%MX\n";
	    }
	    while (($host, $tmp) = each %ext_srv) {
		print DIGBATCH "$host A \%SRV\n";
	    }
	    while (($host, $tmp) = each %ext_ptr) {
		print DIGBATCH "$host A \%PTR\n";
	    }
	    while (($host, $tmp) = each %ext_afsdb) {
		print DIGBATCH "$host A \%AFSDB\n";
	    }
	    while (($host, $tmp) = each %ext_rt) {
		print DIGBATCH "$host A \%RT\n";
	    }
	    while (($host, $tmp) = each %ext_rp) {
		print DIGBATCH "$host TXT \%RP\n";
	    }
	    while (($host, $tmp) = each %ext_cname) {
		print DIGBATCH "$host ANY \%CNAME\n";
	    }
	    close(*DIGBATCH);

	    if ($answer == 1) {
		$tmp = "query for an out-of-zone domain";
	    } else {
		$tmp = "queries for out-of-zone domains";
	    }
	    print STDOUT "(processing $answer $tmp)\n";
	    $query_options = " +noauthority +noadditional +nostats"
			   . " +$DiG_Timeout +$DiG_Retries";
	    while (-s $dig_batch) {
		#
		# Call DiG to process the original batch file plus any
		# subsequent batch files that get generated as a result
		# of following chained CNAMEs.
		#
		$debug_file = "$Debug_DIR/h2n-dig.ans${i}_$Data_Fname";
		if ($Debug) {
		    unless (open(*DEBUGOUT, '>', $debug_file)) {
			print STDERR "Error opening `$debug_file': $!\n",
				     "Disabling the -debug option for the ",
				     "remainder of the program.\n";
			$Debug = 0;
		    }
		}
		unless (open(*DIGOUT, '-|',
			     "$DiG $query_options -f $dig_batch 2>&1")) {
		    print STDERR "Error running the `$DiG' program: $!\n",
				 "Unable to check external domain names.\n";
		    %Ext_NS = %ext_mx = %ext_srv = %ext_ptr = %ext_afsdb
			    = %ext_rt = %ext_rp = %ext_cname = ();
		    close(*DEBUGOUT) if $Debug;
		    $nextbatch = "";
		    last;
		}
		$i++;
		$chain_length++;
		$nextbatch = "$Debug_DIR/h2n-dig.bat${i}_$Data_Fname";
		unless (open(*NEXTBATCH, '>', $nextbatch)) {
		    $nextbatch_is_open = 0;
		} else {
		    $nextbatch_is_open = 1;
		}
		$rrtype = $saved_cname = "";
		while (<DIGOUT>) {
		    print DEBUGOUT $_ if $Debug;
		    chop;
		    next if /^$/;
		    if (/^; <<>> DiG \d+[.]\d+.* <<>>.* (\S+) (AN?Y?|TXT) %(NS|MX|SRV|PTR|AFSDB|RT|RP|CNAME)=?(\S+)?/) {
			$host = $1;
			$rrtype = $3;
			$cname = $4;
			if ($rrtype eq 'CNAME') {
			    #
			    # Deal with the various workarounds that this
			    # program has to make in order to accommodate a
			    # small internal buffer size in DiG version 8.2
			    # and earlier whereby it overruns the buffer when
			    # reading a line from a batch file that exceeds
			    # 100 characters in length.
			    #
			    if ($chain_length == 1) {
				#
				# When the original batch file is created,
				# the starting CNAME ($cname) is identical
				# to the domain name to be queried ($host).
				# To save buffer space, the redundant field
				# is not written to the batch file.
				#
				$cname = $host;
			    } elsif ($host eq '<NO-OP>') {
				#
				# When subsequent batch files are created to
				# follow chained CNAMEs, it may be necessary
				# to split the batch file entry into two lines.
				# A dummy name is assigned to "$host" followed
				# by the real base CNAME in its expected field.
				#
				$saved_cname = $cname;
			    } elsif ($saved_cname) {
				#
				# This section is reached when the second line
				# of the split-line work-around is reached.
				# The "$host" variable contains the chained
				# CNAME to be queried while the "$cname"
				# variable has just been set to null.
				# Restore the value of the base CNAME from the
				# prior input line to complete the work-around.
				#
				$cname = $saved_cname;
				$saved_cname = "";
			    }
			}
			$status = $result = "";
			$query_section = $first_answer = 0;
			next;
		    } elsif (/^;.+(?:connection |no route|unreachable|...malformed|packet size error|Message too long)/i) {
			#
			# Check the "$rrtype" variable as a precaution against
			# accidentally overwriting the result of the last
			# successful lookup in case synchronization is lost.
			# This step is necessary in order to accommodate
			# versions 9.0.1 of DiG which fail to echo the command
			# line when encountering any type of connection failure.
			#
			next unless $rrtype;
			s/.+(timed out).*/ $1  /;
			s/.+(refused).*/con. $1/;
			s/.+(no route).+/  $1  /;
			s/.+(unreachable).+/$1 /;
			s/.+(?:...malformed|packet size error|Message too long).*/bad DNS msg./i;
			$result = $_;
			#
			# Instead of getting the next line, we'll fall through
			# to the section where a non-null "$result" variable
			# is processed and throw in the towel for this batch
			# file entry.  It's pointless and likely futile to
			# wait for the sanity check in the Query Section.
			#
		    } elsif (/^;.+HEADER.+opcode: QUERY, status: ([^,]+)/) {
			$status = $1;
			if ($status ne 'NOERROR') {
			    $status = " $status " if length($status) == 6;
			    $status .= " " if length($status) < 8;
			    $result = "  $status  ";
			    $status = "";
			}
			next;		# trust nothing until the Query Section
		    } elsif ($status && /^;.+flags: (.*); QUE.*, ANS[^:]*: (\d+), AUTH[^:]*: (\d+), ADDIT[^:]*: (\d+)/i) {
			$flags = $1;
			$answer = $2;
			$authority = $3;
			$additional = $4;
			if ($answer == 0) {
			    if ($rrtype ~~ /^(?:NS|MX|SRV|PTR|AFSDB|RT)$/) {
				$result = "no A record ";
			    } elsif ($rrtype eq 'RP') {
				$result = " no TXT RR  ";
			    } else {
				#
				# Hmm.  The domain name must exist since
				# the status of the query is NOERROR and
				# yet there are no answers for ANY resource
				# records.  This can happen when querying
				# for an interior label of an existing
				# domain name, e.g.,
				#
				#  a.foo.example.com   exists as a RR in the
				#                      `example.com' zone
				#  foo.example.com     does *not* exist as a RR
				#
				# We would be here if an ANY query were made
				# for the domain name `foo.example.com' since
				# no RRs exist at that node in the DNS
				# namespace hierarchy.
				#
				$result = "no RRs exist";
			    }
			    $status = "";
			} else {
			    #
			    # Prepare for the Answer Section once we pass
			    # the sanity check in the Query Section.
			    #
			    $first_answer = 1;
			}
			next;		# trust nothing until the Query Section
		    } elsif (/^;; QUE.+:$/) {
			$query_section = 1;
			next;
		    }
		    next if !$rrtype || $host eq '<NO-OP>';
		    if ($query_section && /^;;?\s*(\S+)\s+/) {
			$tmp = lc($1);
			$query_section = 0;
			if ($tmp ~~ /,$/) {
			    #
			    # DiG versions through 8.X match this pattern.
			    #
			    $tmp ~~ s/,$/./;
			    $tmp = "." if $tmp eq "..";	# '.' zone special case
			}
			if ($tmp ne lc($host)) {
			    #
			    # The domain name that was passed to DiG in the
			    # batch file and which appears on the echoed
			    # command line is *not* what DiG actually used
			    # when making its query.  A line in the batch
			    # file that exceeded "$DiG_Bufsize" in length
			    # is the likely source of DiG's buffer overrun.
			    # All we can do now is report what occurred and
			    # then resynchronize on the next line from the
			    # batch input file.
			    #
			    $result = "buffer error";
			    $status = "";
			    $first_answer = 0;
			    if ($chain_length > 1
				&& exists($base_cname{$host})) {
				#
				# Recover the "$cname" field that was most
				# likely trashed due to the buffer overrun.
				#
				$cname = $base_cname{$host};
			    }
			}
		    }
		    if ($chain_length > 1) {
			#
			# The backup copy of the base CNAME is no longer needed.
			# Remove the chained CNAME key for possible re-use.
			#
			delete($base_cname{$host});
		    }
		    if ($result) {
			if ($rrtype eq 'NS') {
			    $Ext_NS{$host} = "[$result]|$Ext_NS{$host}";
			} elsif ($rrtype eq 'MX') {
			    $ext_mx{$host} = "[$result]|$ext_mx{$host}";
			} elsif ($rrtype eq 'SRV') {
			    $ext_srv{$host} = "[$result]|$ext_srv{$host}";
			} elsif ($rrtype eq 'PTR') {
			    $ext_ptr{$host} = "[$result]|$ext_ptr{$host}";
			} elsif ($rrtype eq 'AFSDB') {
			    $ext_afsdb{$host} = "[$result]|$ext_afsdb{$host}";
			} elsif ($rrtype eq 'RT') {
			    $ext_rt{$host} = "[$result]|$ext_rt{$host}";
			} elsif ($rrtype eq 'RP') {
			    $ext_rp{$host} = "[$result]|$ext_rp{$host}";
			} else {
			    if ($chain_length == 1) {
				#
				# Despite the name of the control variable,
				# there's no CNAME chain here; a bigger
				# problem has caused us to bail out early.
				#
				if ($Show_Dangling_CNAMEs
				    || $result !~ /(?:NXDOMAIN|no RRs exist)/) {
				    $ext_cname{$cname} = "[$result]"
						       . "|$ext_cname{$cname}";
				} else {
				    #
				    # We are not interested in reporting any
				    # dangling CNAMEs.
				    #
				    delete($ext_cname{$cname});
				}
			    } elsif (exists($ext_cname{$cname})) {
				#
				# The reason we tested for the existence of
				# "$cname" as a hash key is that we might
				# not have been able to recover the backup
				# copy after a buffer overrun was detected.
				#
				if ($Show_Chained_CNAMEs
				    || $Show_Dangling_CNAMEs
				    || $result !~ /(?:NXDOMAIN|no RRs exist)/) {
				    $ext_cname{$cname} ~~ s/\[.+\]/[$result]/;
				    $max_chain_length = $chain_length;
				} else {
				    delete($ext_cname{$cname});
				}
			    }
			}
			# Setting "$rrtype" to null after detecting either a
			# buffer overrun or a non-NOERROR query status will
			# effectively ignore DiG's output until the next echoed
			# DiG command in the output stream.  This effectively
			# allows a resynchronization to take place and prevents
			# the accidental overwriting of valid data.
			#
			$rrtype = "" if $result eq "buffer error" || !$status;
			$result = "";
		    }
		    next unless $status;
		    if ($first_answer && /^[^;]/) {
			if (/\sCNAME\s+(\S+)$/) {
			    $cname_n = lc($1);
			    if ($rrtype eq 'NS') {
				$Ext_NS{$host} = "[CNAME record]"
					       . "|$Ext_NS{$host}";
			    } elsif ($rrtype eq 'MX') {
				$ext_mx{$host} = "[CNAME record]"
					       . "|$ext_mx{$host}";
			    } elsif ($rrtype eq 'SRV') {
				$ext_srv{$host} = "[CNAME record]"
						. "|$ext_srv{$host}";
			    } elsif ($rrtype eq 'PTR') {
				$ext_ptr{$host} = "[CNAME record]"
						. "|$ext_ptr{$host}";
			    } elsif ($rrtype eq 'AFSDB') {
				$ext_afsdb{$host} = "[CNAME record]"
						  . "|$ext_afsdb{$host}";
			    } elsif ($rrtype eq 'RT') {
				$ext_rt{$host} = "[CNAME record]"
					       . "|$ext_rt{$host}";
			    } elsif ($rrtype eq 'RP') {
				$ext_rp{$host} = "[CNAME record]"
					       . "|$ext_rp{$host}";
			    } else {
				#
				# Follow the CNAME chain.
				#
				$cname_loop = 0;
				if ($chain_length == 1) {
				    #
				    # Regardless of one's opinion about CNAME
				    # chains being bad practice or a feature,
				    # record this status as well as the current
				    # chain length until final resolution can
				    # be determined.  This program's default
				    # behavior is to treat chained CNAMEs as
				    # no problem as long as a non-CNAME RR is
				    # ultimately resolved.
				    #
				    $ext_cname{$cname} = "[CNAME chain ](1)"
						      . "|$ext_cname{$cname}";
				    $chain_cname{$cname} = [ $cname ];
				}
				for ($k = 0; $k < $chain_length; $k++) {
				    #
				    # Before rushing off to follow the latest
				    # CNAME, make sure it's not one that we've
				    # already encountered in the current chain.
				    #
				    if ($chain_cname{$cname}[$k] eq $cname_n) {
					$ext_cname{$cname} ~~
				     s/^[^\|]+/[ CNAME loop ]\($chain_length\)/;
					$cname_loop = 1;
					last;
				    }
				}
				#
				# Regardless of whether or not we've discovered
				# a CNAME loop, maintain accuracy by updating
				# the chain length of the base CNAME and add
				# the latest CNAME to the list of chain members.
				#
				$ext_cname{$cname} ~~
					     s/ \]\(\d+\)/ \]\($chain_length\)/;
				push @{ $chain_cname{$cname} }, $cname_n;
				if ($nextbatch_is_open && !$cname_loop) {
				    #
				    # Find out where the chained CNAME leads us
				    # by creating the appropriate entry in the
				    # pending DiG batch file.
				    #
				    $buffer = "$cname_n ANY \%CNAME=$cname\n";
				    if (length($buffer) > $DiG_Bufsize) {
					#
					# Avoid creating a buffer overrun in
					# DiG by splitting the necessary data
					# across two lines of batch input.
					#
					print NEXTBATCH "<NO-OP> ANY ",
							"\%CNAME=$cname\n";
					print NEXTBATCH "$cname_n ANY ",
							"\%CNAME\n";
				    } else {
					print NEXTBATCH $buffer;
					#
					# If a buffer overrun occurs despite
					# our efforts, the field most likely
					# to be trashed is the one holding the
					# value of "$cname".  As an exercise in
					# paranoid programming, we'll create
					# a reverse-lookup hash as a way to
					# recover the base CNAME in case our
					# fears are realized.
					#
					unless (exists($base_cname{$cname_n})) {
					    $base_cname{$cname_n} = $cname;
					} else {
					    #
					    # No can do.  Another base CNAME
					    # has already submitted a query to
					    # the current batch file for the
					    # same chained CNAME.  Not only do
					    # we have to give up the current
					    # backup attempt, the original base
					    # CNAME that got here first must
					    # also abandon its backup copy.
					    #
					    $base_cname{$cname_n} = "";
					}
				    }
				} else {
				    #
				    # The buck just stopped.
				    # Update the cosmetic control variable.
				    #
				    $max_chain_length = $chain_length;
				}
			    }
			} else {
			    #
			    # All is well - either an Address RR exists for the
			    # object of the NS, MX, or PTR RR or the CNAME RR
			    # points to something other than another CNAME.
			    #
			    if ($rrtype eq 'NS') {
				delete($Ext_NS{$host});
			    } elsif ($rrtype eq 'MX') {
				delete($ext_mx{$host});
			    } elsif ($rrtype eq 'SRV') {
				delete($ext_srv{$host});
			    } elsif ($rrtype eq 'PTR') {
				delete($ext_ptr{$host});
			    } elsif ($rrtype eq 'AFSDB') {
				delete($ext_afsdb{$host});
			    } elsif ($rrtype eq 'RT') {
				delete($ext_rt{$host});
			    } elsif ($rrtype eq 'RP') {
				delete($ext_rp{$host});
			    } elsif ($Show_Chained_CNAMEs &&
				     $ext_cname{$cname} ~~ /\]\(\d+\)/) {
				$max_chain_length = $chain_length;
			    } else {
				delete($ext_cname{$cname});
			    }
			}
			$first_answer = 0;	# Ignore remaining output until
			$rrtype = $status = "";	# the next batch entry is read.
		    }
		}
		close(*NEXTBATCH) if $nextbatch_is_open;

		# BIND's observed limits of chasing CNAME chains are:
		#
		# * BIND 8 will chase 8 CNAMEs - if #8 points to a non-CNAME
		#   RR, you'll get the answer.   If #8 points to yet another
		#   CNAME, you'll get the 9 CNAMEs and the response code will
		#   be set to SERVFAIL.
		#
		# * BIND 9 will chase 16 CNAMEs - if #16 points to a non-CNAME
		#   RR, you'll get the answer.    If #16 points to yet another
		#   CNAME, you'll get the 17 CNAMEs with a NOERROR response
		#   code.
		#
		# The loop that follows chained CNAMEs will exhaust itself
		# naturally or when the 17th iteration is reached.
		#
		unlink($nextbatch) if -z $nextbatch;
		if ($chain_length == 17) {
		    unlink($nextbatch) unless $Debug;
		    $nextbatch = "";
		    $max_chain_length = 17;
		}
		close(*DIGOUT);
		if ($Debug) {
		    close(*DEBUGOUT);
		} else {
		    unlink($dig_batch);
		    #
		    # Clean up any leftover debug file of DiG's output
		    # from a prior run if the -debug option was specified.
		    #
		    unlink($debug_file) if -e $debug_file;
		}
		$dig_batch = $nextbatch;
	    }
	}
    }

    # Ideally, all of the hashes should be empty.
    # If not, here's where the warnings get reported.
    # Note: The `if' tests are structured to prevent short-circuiting so
    #       that there are no passed-over calls to the keys() function
    #       for initializing the iterator of each hash.
    #
    if ((keys(%NSlist) + keys(%Ext_NS))) {
	print STDERR "${n}Warning: found NS RR(s) pointing to ",
		     "the following problematic domain name(s):\n";
	$n = "";
	while (($host, $tmp) = each %NSlist) {
	    #
	    # If DiG generates output that is unexpected in either content
	    # or sequence and it is detected by the `h2n' output parser,
	    # the value of the hash index may lack the assignment of the
	    # status field as the parser attempts to resynchronize.
	    # In such cases, assign a generic status field that indicates
	    # roughly what happened.
	    #
	    $host .= ".$Audit_Domain" unless $host ~~ /(?:^|[^\\])[.]$/;
	    $tmp = "[sync. error ]|$tmp" unless $tmp ~~ /\|/;
	    ($status, $location) = split(/\|/, $tmp, 2);
	    $location = "" if $Verify_Mode && $location ne "(SOA MNAME)";
	    printf STDERR "%s%s  %s\n", TAB(" $host", $t), $status, $location;
	}
	while (($host, $tmp) = each %Ext_NS) {
	    $tmp = "[sync. error ]|$tmp" unless $tmp ~~ /\|/;
	    ($status, $location) = split(/\|/, $tmp, 2);
	    $location = "" if $Verify_Mode && $location ne "(SOA MNAME)";
	    printf STDERR "%s%s  %s\n", TAB(" $host", $t), $status, $location;
	}
    }
    if ((keys(%MXlist) + keys(%ext_mx))) {
	print STDERR "${n}Warning: found MX RR(s) pointing to ",
		     "the following problematic domain name(s):\n";
	$n = "";
	while (($host, $tmp) = each %MXlist) {
	    $host .= ".$Audit_Domain" unless $host ~~ /(?:^|[^\\])[.]$/;
	    $tmp = "[sync. error ]|$tmp" unless $tmp ~~ /\|/;
	    ($status, $location) = split(/\|/, $tmp, 2);
	    $location = "" if $Verify_Mode;
	    printf STDERR "%s%s  %s\n", TAB(" $host", $t), $status, $location;
	}
	while (($host, $tmp) = each %ext_mx) {
	    $tmp = "[sync. error ]|$tmp" unless $tmp ~~ /\|/;
	    ($status, $location) = split(/\|/, $tmp, 2);
	    $location = "" if $Verify_Mode;
	    printf STDERR "%s%s  %s\n", TAB(" $host", $t), $status, $location;
	}
    }
    if ((keys(%Spcl_SRV) + keys(%ext_srv))) {
	print STDERR "${n}Warning: found SRV RR(s) pointing to ",
		     "the following problematic domain name(s):\n";
	$n = "";
	while (($host, $tmp) = each %Spcl_SRV) {
	    $host .= ".$Audit_Domain" unless $host ~~ /(?:^|[^\\])[.]$/;
	    $tmp = "[sync. error ]|$tmp" unless $tmp ~~ /\|/;
	    ($status, $location) = split(/\|/, $tmp, 2);
	    $location = "" if $Verify_Mode;
	    printf STDERR "%s%s  %s\n", TAB(" $host", $t), $status, $location;
	}
	while (($host, $tmp) = each %ext_srv) {
	    $tmp = "[sync. error ]|$tmp" unless $tmp ~~ /\|/;
	    ($status, $location) = split(/\|/, $tmp, 2);
	    $location = "" if $Verify_Mode;
	    printf STDERR "%s%s  %s\n", TAB(" $host", $t), $status, $location;
	}
    }
    if ((keys(%Spcl_PTR) + keys(%ext_ptr))) {
	print STDERR "${n}Warning: found PTR RR(s) pointing to ",
		     "the following problematic domain name(s):\n";
	$n = "";
	while (($host, $tmp) = each %Spcl_PTR) {
	    $host .= ".$Audit_Domain" unless $host ~~ /(?:^|[^\\])[.]$/;
	    $tmp = "[sync. error ]|$tmp" unless $tmp ~~ /\|/;
	    ($status, $location) = split(/\|/, $tmp, 2);
	    $location = "" if $Verify_Mode;
	    printf STDERR "%s%s  %s\n", TAB(" $host", $t), $status, $location;
	}
	while (($host, $tmp) = each %ext_ptr) {
	    $tmp = "[sync. error ]|$tmp" unless $tmp ~~ /\|/;
	    ($status, $location) = split(/\|/, $tmp, 2);
	    $location = "" if $Verify_Mode;
	    printf STDERR "%s%s  %s\n", TAB(" $host", $t), $status, $location;
	}
    }
    if ((keys(%Spcl_AFSDB) + keys(%ext_afsdb))) {
	print STDERR "${n}Warning: found AFSDB RR(s) pointing to ",
		     "the following problematic dom. name(s):\n";
	$n = "";
	while (($host, $tmp) = each %Spcl_AFSDB) {
	    $host .= ".$Audit_Domain" unless $host ~~ /(?:^|[^\\])[.]$/;
	    $tmp = "[sync. error ]|$tmp" unless $tmp ~~ /\|/;
	    ($status, $location) = split(/\|/, $tmp, 2);
	    $location = "" if $Verify_Mode;
	    printf STDERR "%s%s  %s\n", TAB(" $host", $t), $status, $location;
	}
	while (($host, $tmp) = each %ext_afsdb) {
	    $tmp = "[sync. error ]|$tmp" unless $tmp ~~ /\|/;
	    ($status, $location) = split(/\|/, $tmp, 2);
	    $location = "" if $Verify_Mode;
	    printf STDERR "%s%s  %s\n", TAB(" $host", $t), $status, $location;
	}
    }
    if ((keys(%Spcl_RT) + keys(%ext_rt))) {
	print STDERR "${n}Warning: found RT RR(s) pointing to ",
		     "the following problematic domain name(s):\n";
	$n = "";
	while (($host, $tmp) = each %Spcl_RT) {
	    $host .= ".$Audit_Domain" unless $host ~~ /(?:^|[^\\])[.]$/;
	    $tmp = "[sync. error ]|$tmp" unless $tmp ~~ /\|/;
	    ($status, $location) = split(/\|/, $tmp, 2);
	    $location = "" if $Verify_Mode;
	    printf STDERR "%s%s  %s\n", TAB(" $host", $t), $status, $location;
	}
	while (($host, $tmp) = each %ext_rt) {
	    $tmp = "[sync. error ]|$tmp" unless $tmp ~~ /\|/;
	    ($status, $location) = split(/\|/, $tmp, 2);
	    $location = "" if $Verify_Mode;
	    printf STDERR "%s%s  %s\n", TAB(" $host", $t), $status, $location;
	}
    }
    if ((keys(%Spcl_RP) + keys(%ext_rp))) {
	print STDERR "${n}Warning: found RP RR(s) pointing to ",
		     "the following problematic TXT domain(s):\n";
	$n = "";
	while (($host, $tmp) = each %Spcl_RP) {
	    $host .= ".$Audit_Domain" unless $host ~~ /(?:^|[^\\])[.]$/;
	    $tmp = "[sync. error ]|$tmp" unless $tmp ~~ /\|/;
	    ($status, $location) = split(/\|/, $tmp, 2);
	    $location = "" if $Verify_Mode;
	    printf STDERR "%s%s  %s\n", TAB(" $host", $t), $status, $location;
	}
	while (($host, $tmp) = each %ext_rp) {
	    $tmp = "[sync. error ]|$tmp" unless $tmp ~~ /\|/;
	    ($status, $location) = split(/\|/, $tmp, 2);
	    $location = "" if $Verify_Mode;
	    printf STDERR "%s%s  %s\n", TAB(" $host", $t), $status, $location;
	}
    }
    if ((keys(%Spcl_CNAME) + keys(%ext_cname))) {
	print STDERR "${n}Warning: found CNAME(s) pointing to ",
		     "the following problematic domain name(s):\n";
	if ($max_chain_length) {
	     print STDERR "(numbers within parentheses represent ",
			  "the length of a CNAME chain)\n";
	}
	$n = "";
	if (!$max_chain_length || $Verify_Mode) {
	    $i = "";
	} else {
	    $i = ($max_chain_length < 10) ?? "   " !! "    ";
	}
	while (($host, $tmp) = each %Spcl_CNAME) {
	    $host .= ".$Audit_Domain" unless $host ~~ /(?:^|[^\\])[.]$/;
	    $tmp = "[sync. error ]|$tmp" unless $tmp ~~ /\|/;
	    ($status, $location) = split(/\|/, $tmp, 2);
	    $status .= ($status ~~ /\)$/) ?? "" !! $i;
	    $location = "" if $Verify_Mode;
	    printf STDERR "%s%s  %s\n", TAB(" $host", $t), $status, $location;
	}
	while (($host, $tmp) = each %ext_cname) {
	    $tmp = "[sync. error ]|$tmp" unless $tmp ~~ /\|/;
	    ($status, $location) = split(/\|/, $tmp, 2);
	    $status .= ($status ~~ /\)$/) ?? "" !! $i;
	    $location = "" if $Verify_Mode;
	    printf STDERR "%s%s  %s\n", TAB(" $host", $t), $status, $location;
	    if ($Show_Chained_CNAMEs && $status ~~ /\]\((\d+)\)/) {
		$chain_length = $1;
		for ($k = 1; $k <= $chain_length; $k++) {
		    print STDERR "  > $chain_cname{$host}[$k]\n";
		}
	    }

	}
    }
    # Undefine data structures that are no longer needed so that
    # the hashes and lists in the NS-related audits that follow
    # have room to grow.
    #
    unless ($Verify_Delegations) {
	undef %NSlist;
	undef %Ext_NS;
    }
    undef %MXlist;
    undef %ext_mx;
    undef %Spcl_SRV;
    undef %ext_srv;
    undef %Spcl_PTR;
    undef %ext_ptr;
    undef %Spcl_AFSDB;
    undef %ext_afsdb;
    undef %Spcl_RT;
    undef %ext_rt;
    undef %Spcl_RP;
    undef %ext_rp;
    undef %Spcl_CNAME;
    undef %ext_cname;
    undef %base_cname;
    undef %chain_cname;

    if (keys(%NSowners)) {
	#
	# Check that each zone has at least two listed name servers
	# and, if so, that the TTLs of the NS RRset are consistent.
	# While we're at it, name servers in child zones will trigger
	# a check for necessary glue in this (the parent) zone.
	#
	$last_zone = "";
	$glue_missing = $glue_over_limit = 0;
	@delete_list = @msg_buf = ();
	while (($zone, $buffer) = each %NSowners) {
	    #
	    # Cycle through the name servers of each zone.  Before plowing
	    # ahead, however, this is the time to identify any invalid
	    # "grandchild" zones that may have come our way, e.g.,
	    #
	    #   $ORIGIN example.com.
	    #   @             IN SOA    ...
	    #   ...
	    #   child           IN NS    ns.child        ; valid delegation
	    #   ns.child        IN A     192.249.249.3   ; valid glue
	    #   child.child     IN NS    ns.child.child  ; invalid delegation
	    #                                            ; NS RR below zone cut
	    #   ns.child.child  IN A     192.249.249.4   ; invalid - non-glue
	    #                                            ; A RR below zone cut
	    #
	    # Up to now, these instances have been treated like any other
	    # domain in that DiG has been called to look up references to
	    # these out-of-zone domains when they have appeared in the RDATA
	    # fields of the record types that `h2n' scrutinizes.
	    # From now on, however, these out-of-context NS records have
	    # no meaning and will be removed from the %NSowners hash.
	    # They'll be reported a bit later as just another occurrence
	    # of non-glue below a zone cut.
	    #
	    if ($zone ne "$Domain.") {
		$status = 1;
		$subzone = $zone;
		while ($subzone ~~ /(?:\\[.]|[^.])*[.]/) {
		    $subzone ~~ s/(?:\\[.]|[^.])*[.]//;	# remove leftmost label
		    if (exists($NSowners{$subzone})) {
			#
			# Our original "$zone" is a bogus delegation because of
			# an existing delegation between it and the parent zone.
			#
			push(@delete_list, $zone);
			$status = 0;
			last;
		    }
		}
		next unless $status;
	    }
	    $ns_count = 0;
	    while ($buffer) {
		#
		# For each zone ($zone) obtained from the "%NSowners" hash,
		# cycle through each listed name server in "$buffer".
		#
		($ttl, $host, $buffer) = split(' ', $buffer, 3);
		$ns_count++;
		if ($ns_count == 1) {
		    $answer = $ttl;
		} elsif ($status) {
		    unless ($ttl == $answer) {
			push(@ns_rfc_2181, $zone);
			$status = 0;
		    }
		}
		unless ($host ~~ /(?:^|[^\\])[.]$/) {
		    #
		    # The domain name of the name server for the (sub)zone
		    # being checked is not absolute.  Another check must be
		    # made to see if this intra-domain name server is located
		    # in a delegated subdomain.  If so, determine if a glue
		    # record is necessary and see if it is present.
		    # NOTE: Per RFC-1034, delegation effectively cancels
		    #       wildcard matching.  Therefore, a wildcard can
		    #       not be used as a glue record, e.g., the
		    #       following A record does *not* qualify as glue:
		    #
		    #         $ORIGIN example.com.
		    #         child      NS   ns.child
		    #         *.child    A    192.168.1.1
		    #
		    #       Unfortunately, not all name server implementations
		    #       treat this condition correctly.  BIND 4/8 will go
		    #       ahead and synthesize the following record in the
		    #       answer or additional section of a response:
		    #
		    #         ns.child.example.com.    A    192.168.1.1
		    #
		    #       This is related to the design limitation of all
		    #       served zones being contained in a single database.
		    #       BIND 9, however, strictly complies with the RFC
		    #       and will *not* match `ns.child.example.com' with
		    #       the wildcard record in the parent zone.
		    #
		    # Be advised that your mileage may vary when this section
		    # is working in verify mode.  That's because name servers
		    # running BIND 4.9 through BIND 8 will fetch glue by
		    # default during the course of answering queries and
		    # include these RRs in an AXFR query (zone transfer).
		    # Disabling this behavior requires that both the recursion
		    # and glue fetching options be set to "no" in the BIND 4/8
		    # configuration file of the authoritative name server.
		    # Conversely, BIND 9 considers indiscriminate glue fetching
		    # a bad idea and will not fetch non-authoritative glue from
		    # a parent zone when it can resolve and cache authoritative
		    # data from the child zone instead.  Also, BIND 9 always
		    # returns only original master zone data in AXFR queries
		    # and never augments the zone transfer with fetched glue.
		    #
		    # While the absolute necessity of glue records is obvious
		    # in the most common case of a name server for a delegated
		    # zone that is also located in the same delegated zone,
		    # the determination of required glue can become more of a
		    # subjective issue when delegation is made among subzones
		    # having the same parent zone in common, i.e., sibling
		    # child zones.
		    # The following example shows one such scenario:
		    #
		    #	$ORIGIN example.com.
		    #	child-1		NS	ns1.child-2
		    #			NS	ns2.child-2
		    #	ns1.child-2	A	192.168.0.1
		    #	ns2.child-2	A	192.168.0.2
		    #
		    #	child-2		NS	ns3.child-1
		    #			NS	ns4.child-1
		    #	ns3.child-1	A	192.168.0.3
		    #	ns4.child-1	A	192.168.0.4
		    #
		    # The above cross-delegation means that all four of the
		    # `A' records are essential glue for resolving domain
		    # names in the `child-1' and `child-2' zones even though
		    # none of the specified name servers are themselves within
		    # the subzone being delegated.
		    # Here's an example of a series of recursive (chained)
		    # delegations:
		    #
		    #	$ORIGIN example.com.
		    #	glueless-4	NS	host1.glueless-3
		    #			NS	host2.glueless-3
		    #	glueless-3	NS	host1.glueless-2
		    #			NS	host2.glueless-2
		    #	glueless-2	NS	host1.glueless-1
		    #			NS	host2.glueless-1
		    #	glueless-1	NS	host1.glue
		    #			NS	host2.glue
		    #	glue		NS	ns1.glue
		    #			NS	ns2.glue
		    #	ns1.glue	A	192.168.0.1
		    #	ns2.glue	A	192.168.0.2
		    #
		    # The essential glue RRs are the A records for `ns1' and
		    # `ns2' in the `glue' subzone.  No glue RRs in the parent
		    # are theoretically necessary to resolve the addresses of
		    # the name servers in the `glueless-[1234]' subzones
		    # because the resolution process should follow the chain
		    # of referrals until the authoritative name servers for
		    # the `glue' subzone are reached.  The glue records for
		    # `ns[12].glue' will then be utilized to resolve the A RRs
		    # for the `glueless-1' name servers (host[12].glue) and so
		    # on back up the chain until the original query is finally
		    # resolved.  Once learned, the addresses of these name
		    # servers will be cached and returned in the Additional
		    # Section of future responses to queries for data in the
		    # `glueless-[1234]' and `glue' subzones.
		    #
		    # However, what's theoretically unnecessary (intermediate
		    # glue records in the above example) may be problematic
		    # in the real world.  For starters, only BIND 9 has the
		    # "query restart" feature to follow long chains of glueless
		    # delegations.  BIND 4/8 name servers have an internal
		    # "sysquery" mechanism that can chase up to three glueless
		    # delegations before giving up and relying on the client
		    # resolver to retry the query.  When network latency and
		    # the possibility of encountering lame/unresponsive name
		    # servers are taken into account, too many glueless
		    # delegations can cause most resolvers to give up after
		    # all of their retry attempts time out.
		    #
		    # A domain hierarchy which naturally consists of recursive
		    # ("glueless") delegations is `in-addr.arpa'.  There can be
		    # quite a number of iterative queries required to work down
		    # the delegation chain of each label of an IP address only
		    # to discover that there's an RFC-2317 CNAME to resolve yet
		    # again.  If the domain name of an authoritative name server
		    # for any `in-addr.arpa' zone is itself glueless, even more
		    # delay can occur during the resolution process.
		    #
		    # By knowing the underlying overhead of resolving a domain
		    # name, prudent hostmasters should include glue records for
		    # subzone delegations under a common parent zone even if
		    # they are theoretically optional.  Such glue won't be
		    # rejected by the parent zone as out-of-domain data and
		    # thus will help the resolution process.  Keeping these
		    # glue records in sync with their authoritative counterparts
		    # is necessary but that needs to be done anyway as part of
		    # the requirement to keep the NS RRsets identical on both
		    # sides of the zone cut.
		    #
		    # For delegations across different domains for which glue
		    # can't be configured, e.g.,
		    #
		    #   $ORIGIN example.com.
		    #	subdomain	NS	ns.sub1.sub2.example.net.
		    #
		    # the resolution process can be helped by arranging for the
		    # authoritative name servers for `example.com' (the zone
		    # making the delegation) to also be authoritative as a
		    # stealth or listed slave for `sub1.sub2.example.net' (the
		    # zone which can supply the address record for the name
		    # server to which `subdomain.example.com' is delegated).
		    #
		    ($subzone, $tmp, $tmp) =
					    MATCH_DOMAIN("$host.$Audit_Domain");
		    if ($subzone) {
			#
			# A glue record may be either mandatory, recommended
			# (to avoid too many levels of glueless recursion), or
			# optional (when limited to only 1-3 levels of glueless
			# delegation).
			# In any case, see if glue exists and register it in
			# the "%glue_rr" hash so that it can be identified
			# a bit later during the check for non-glue records
			# at or below a zone cut.
			#
			$glue_found = 0;
			if (exists($glue_rr{$host})) {
			    $glue_found = 1;
			} else {
			    if (!$Verify_Mode && exists($Hosts{$host})) {
				$glue_rr{$host} = $glue_found = 1;
			    } elsif (exists($RRowners{$host})) {
				if ($RRowners{$host} ~~ / (?:A|AAAA) /) {
				    $glue_rr{$host} = $glue_found = 1;
				}
			    }
			}
			next if $glue_found;
			$glue_problem = 0;
			if ("$zone.$Audit_Domain" eq $subzone
			    || $zone eq "$Domain.") {
			    #
			    # This is the classic case of a "bootstrap" glue
			    # record being mandatory.  This name server is
			    # either in the same subdomain that's being
			    # delegated or it's a server for the parent domain
			    # ($Domain) that's located in one of its delegated
			    # subdomains.
			    #
			    $glue_missing++;
			    $glue_problem = 1;
			} else {
			    #
			    # This name server ($host) for the subzone being
			    # iterated ($zone) is in some other delegated
			    # subdomain ($subzone) of the common parent domain,
			    # i.e., a sibling subzone.
			    # Follow each of the sibling subzone's name server
			    # delegations while keeping track of the number
			    # of chained subzone traversals.  A subzone
			    # traversal along a particular name server path
			    # stops when one of the following conditions is
			    # reached:
			    #
			    #   1. The glueless level exceeds the hard limit
			    #      of "$Glueless_Upper_Limit".  Any pending
			    #      delegation traversal is cancelled.
			    #   2. Encountering a name server in a subzone
			    #      which has already been seen in the current
			    #      traversal, i.e., a cross-delegation.
			    #   3. Encountering a name server that is in the
			    #      parent zone or is in an external domain.
			    #   4. Encountering a name server that either has
			    #      glue or for which ordinary "bootstrap" glue
			    #      is mandatory.
			    #
			    # If none of these conditions are met, the name
			    # server is deemed to be glueless and the sibling
			    # subzone in which it resides is added to the
			    # traversal queue.  This traversal strategy will
			    # discover the longest path of delegations which
			    # are "gluelessly" chained together.
			    # NOTE: The default value for "$Glueless_Limit"
			    #       is determined from the DB-GLUELESS-LIMIT
			    #       VERIFY-GLUELESS-LIMIT settings in the
			    #       'h2n.conf' configuration file.  It can
			    #       also be set as a command-line parameter by
			    #       specifying the `-glueless-limit' option.
			    #
			    %already_seen = ();
			    $already_seen{$zone} = $glueless_depth = 0;
			    ($chained_subzone = $subzone) ~~
							s/$Domain_Pattern[.]$//;
			    @subzone_queue = ($chained_subzone,
					      $glueless_depth);
			    while (@subzone_queue) {
				($chained_subzone, $glueless_depth) =
						   splice(@subzone_queue, 0, 2);
				$glueless_depth++;
				if ($glueless_depth > $Glueless_Upper_Limit) {
				    #
				    # Give up if the chain becomes ridiculous.
				    #
				    $glue_missing++;
				    $glue_problem = 1;
				    last;
				}
				if (exists($already_seen{$chained_subzone})) {
				    #
				    # A name server in the delegation chain has
				    # pointed to an already-traversed sibling
				    # subzone.
				    #
				    if ($already_seen{$chained_subzone} == 0) {
					#
					# The other end of this cross-delegation					# through zero or more chained subzones
					# is the initial subzone which is
					# delegated to "$host".  A glue record
					# is mandatory and all queued subzone
					# traversals are cancelled.
					#
					$glue_missing++;
					$glue_problem = 1;
					last;
				    }
				    # The discovered cross-delegation does not
				    # reach back to the initial subzone of this
				    # traversal.  Some other traversal will
				    # identify (or has already identified) the
				    # mandatory glue record that is missing.
				    # The current traversal along this name
				    # server path, however, has come to an end.
				    #
				    next;
				}
				$already_seen{$chained_subzone} =
								$glueless_depth;
				%already_queued = ();
				$ns_list = $NSowners{$chained_subzone};
				while ($ns_list) {
				    #
				    # See where each name server of the
				    # current sibling subzone leads us.
				    #
				    ($tmp, $ns_host, $ns_list) =
							split(' ', $ns_list, 3);
				    if ($ns_host ~~ /(?:^|[^\\])[.]$/) {
					#
					# The name server's domain name is
					# absolute and thus is not located
					# within a sibling subdomain of the
					# parent zone.  Whether the host is at
					# the apex of the parent zone or in
					# external domain, glue chasing down
					# this particular delegation path has
					# come to an end.
					#
					next;
				    }
				    ($ns_subzone, $tmp, $tmp) =
					 MATCH_DOMAIN("$ns_host.$Audit_Domain");
				    if (!$ns_subzone || ($ns_subzone
					eq "$chained_subzone.$Audit_Domain")) {
					#
					# The name server is either in the
					# parent domain (we aren't looking for
					# authoritative glue in this section)
					# or it's in the same subzone that's
					# being delegated ($chained_subzone)
					# for which "bootstrap" glue is
					# mandatory (this type of glue is
					# checked elsewhere).  In either case,
					# the chase for glue along this
					# traversal path has come to an end.
					#
					next;
				    }
				    $glue_found = 0;
				    if (exists($glue_rr{$ns_host})) {
					$glue_found = 1;
				    } else {
					if (!$Verify_Mode
					    && exists($Hosts{$ns_host})) {
					    $glue_rr{$ns_host} = $glue_found
								= 1;
					} elsif (exists($RRowners{$ns_host})) {
					    if ($RRowners{$ns_host}
						~~ / (?:A|AAAA) /) {
						$glue_rr{$ns_host}= $glue_found
								   = 1;
					    }
					}
				    }
				    next if $glue_found;
				    #
				    # We've found a glueless name server in a
				    # sibling subzone.  Add the subzone in
				    # which it resides to the queue of chained
				    # delegations through which we'll continue
				    # the search for glue.
				    #
				    $ns_subzone ~~ s/$Domain_Pattern[.]$//;
				    unless ($already_queued{$ns_subzone}) {
					push(@subzone_queue, $ns_subzone,
							     $glueless_depth);
					$already_queued{$ns_subzone} = 1;
				    }
				}
			    }
			    if ($glueless_depth > $Glueless_Limit) {
				$glue_over_limit++;
				$glue_problem = 1;
				if ($glueless_depth > $Glueless_Upper_Limit) {
				    $glueless_depth = ">$Glueless_Upper_Limit";
				}
				# Add a comment field to the displayed NS RR
				# that indicates the number of glueless
				# delegations that were followed before before
				# finally encountering a glue record or proving
				# the complete absence of mandatory glue.
				#
				$host = TAB($host, 24) . "; ($glueless_depth)";
			    }
			}
			if ($glue_problem) {
			    if ($zone ne $last_zone) {
				$last_zone = $zone;
				$authority = ($zone eq "$Domain.") ?? '@'
								   !! $zone;
				push(@msg_buf,
				     sprintf("%s\tNS\t%s\n",
					     TAB(" $authority", 24), $host));
			    } else {
				push(@msg_buf,
				     sprintf("%s\tNS\t%s\n",
					     TAB(" ", 24), $host));
			    }
			}
		    }
		}
	    }
	    push(@ns_rfc_1034, $zone) if $ns_count == 1
				       && $Show_Single_Delegations;
	}
	# Now that we're no longer iterating over %NSowners, remove
	# the bogus delegations that were marked for deletion.
	#
	foreach $subzone (@delete_list) {
	    delete($NSowners{$subzone});
	}

	if (@ns_rfc_1034) {
	    print STDERR "${n}Warning: found zone(s) not having at least two ",
			 "listed name servers (RFC-1034):\n \$ORIGIN $Domain.",
			 "\n";
	    $n = "";
	    foreach $zone (@ns_rfc_1034) {
		($ttl, $host) = split(' ', $NSowners{$zone}, 2);
		$authority = ($zone eq "$Domain.") ?? '@' !! $zone;
		printf STDERR "%s\t%s\tIN NS\t%s\n", TAB(" $authority", 16),
			      $ttl, $host;
	    }
	}

	if (@ns_rfc_2181) {
	    print STDERR "${n}Warning: found NS RRset(s) with inconsistent ",
			 "TTL values (RFC-2181):\n \$ORIGIN $Domain.\n";
	    $n = "";
	    foreach $zone (@ns_rfc_2181) {
		$buffer = $NSowners{$zone};
		$ns_count = 1;
		while ($buffer) {
		    ($ttl, $host, $buffer) = split(' ', $buffer, 3);
		    if ($ns_count == 1) {
			$authority = ($zone eq "$Domain.") ?? '@' !! $zone;
			printf STDERR "%s\t%s\tIN NS\t%s\n",
				      TAB(" $authority", 16), $ttl, $host;
		    } else {
			printf STDERR "%s\t%s\tIN NS\t%s\n",
				      TAB(" ", 16), $ttl, $host;
		    }
		    $ns_count++;
		}
	    }
	}

	if (@msg_buf) {
	    $buffer = "${n}Warning: ";
	    if ($glue_missing) {
		$buffer .= "found NS RR(s) to be missing the required glue "
			 . "record";
		if ($glue_over_limit) {
		    $buffer .= " and\n"
		}
	    }
	    if ($glue_over_limit) {
		if ($glue_missing) {
		    $buffer .= "         "
		}
		$buffer .= "found NS RR(s) with an excessively-long delegation "
			 . "chain";
	    }
	    print STDERR "$buffer:\n";
	    if ($glue_over_limit) {
		print STDERR "(commented numbers are delegation chains ",
			     "exceeding the \"glueless\" limit of ",
			     "$Glueless_Limit)\n";
	    }
	    print STDERR " \$ORIGIN $Domain.\n";
	    $n = "";
	    foreach $buffer (@msg_buf) {
		print STDERR $buffer;
	    }
	}

	# Undefine data structures that are no longer needed in order to
	# provide the "%non_glue_rr" hash with the maximum amount of headroom.
	#
	undef @ns_rfc_1034;
	undef @ns_rfc_2181;
	undef @delete_list;
	undef @msg_buf;
	undef @subzone_queue;
	undef %already_seen;

	# Starting with BIND 8.2.3 but not (yet) in BIND 9, master zones will
	# not load if non-glue, non-address resource records appear at or
	# below any zone cut.  In other words, no child-zone data is (should be)
	# permitted in the parent zone unless it is glue.
	# Now that all child zones and resource records are known and existing
	# glue has been identified, this inspection can proceed.
	#
	scalar(keys(%RRowners));
	while (($host, $rrtype) = each %RRowners) {
	    next if $host eq "$Domain.";
	    $fq_host = ($host ~~ /[.]$/) ?? $host !! "$host.$Audit_Domain";
	    ($subzone, $tmp, $tmp) = MATCH_DOMAIN($fq_host);
	    if ($subzone) {
		if ($fq_host eq $subzone) {
		    #
		    # We are at a zone cut.  Remove the NS RRtype
		    # and, if present, any DNSSEC-related RRtypes.
		    #
		    1 while $rrtype ~~ s/ (?:NS|DS|$DNSSEC_RRtypes) / /go;
		}
		if (exists($glue_rr{$host})) {
		    #
		    # This domain name exists as required glue - which is good.
		    # What's bad is if the domain name has a record type other
		    # than A or AAAA (if we're still at a zone cut, the NS
		    # and DNSSEC records have already been taken care of).
		    #
		    1 while $rrtype ~~ s/ (?:A|AAAA) / /g;
		}
		next if $rrtype eq " ";
		$non_glue_rr{$host} = $rrtype;
	    }
	}
	scalar(keys(%Hosts));
	while (($host, $tmp) = each %Hosts) {
	    $host = lc($host);		# in case the -P option is in effect
	    ($subzone, $tmp, $tmp) = MATCH_DOMAIN("$host.$Audit_Domain");
	    if ($subzone) {
		#
		# Only A records of canonical names are represented in the
		# "%Hosts" hash.  These will either be glue or non-glue.
		#
		next if exists($glue_rr{$host});
		$non_glue_rr{$host} = " A ";
	    }
	}
	if (keys(%non_glue_rr)) {
	    print STDERR "${n}Warning: found the following non-glue domain ",
			 "name(s) at or below a zone cut:\n \$ORIGIN $Domain.",
			 "\n";
	    $n = "";
	    $warning = 0;
	    while (($host, $rrtype) = each %non_glue_rr) {
		$match = 1;
		while ($rrtype ~~ /\S/) {
		    $tmp = $rrtype;
		    $tmp ~~ /^\s*(\S+)(.*)/;
		    $tmp = $1;
		    $rrtype = $2;
		    $warning = 1 unless $tmp ~~ /^(?:A|AAAA)$/;
		    if ($match) {
			printf STDERR "%s%s\t...\n", TAB(" $host", 32), $tmp;
			$match = 0;
		    } else {
			printf STDERR "%s%s\t...\n", TAB(" ", 32), $tmp;
		    }
		}
	    }
	    unless ($Verify_Mode) {
		$Load_Status = 3 if $warning && $BIND_Version_Num >= 80203
					     && $BIND_Version_Num < 90000;
	    }
	}
    }

    if ($n) {
	return 0;
    } else {
	print STDERR "\n" unless $Verify_Mode;
	return 1;
    }
}



#
# Do some basic sanity checks on the SOA timer values.  These checks
# are the same ones that BIND performs when a zone is loaded.
#
# Return values:
#   0 = no warnings
#   1 = warnings
#
sub CHECK_SOA_TIMERS {
    my ($expire, $expire_sec, $message, $n, $refresh, $refresh_sec);
    my ($retry, $retry_sec, $ttl, $ttl_sec);

    # If the READ_RRs subroutine detected a bad or missing SOA timer,
    # there is no point in proceeding.  Exit with a successful return
    # code since the error has already been reported.
    #
    return 0 unless $Valid_SOA_Timers;

    $refresh = ($Refresh) ?? $Refresh !! $DefRefresh;
    $retry   = ($Retry) ?? $Retry !! $DefRetry;
    $expire  = ($Expire) ?? $Expire !! $DefExpire;
    if ($Ttl) {
	$ttl = $Ttl;
    } else {
	$ttl = ($RFC_2308) ?? $DefNegCache !! $DefTtl;
    }
    $refresh_sec = SECONDS($refresh);
    $retry_sec   = SECONDS($retry);
    $expire_sec  = SECONDS($expire);
    $ttl_sec     = SECONDS($ttl);
    $message     = "";

    if ($expire_sec < ($refresh_sec + $retry_sec)) {
	$message = " SOA expire value is less than SOA refresh"
		 . " + retry\n   [$expire < $refresh + $retry]";
    }
    if ($expire_sec < ($refresh_sec + (10 * $retry_sec))) {
	$n = ($message) ?? ".\n" !! "";
	$message .= "$n SOA expire value is less than SOA refresh "
		  . "+ (10 * retry)\n   [$expire < $refresh + (10 * $retry)]";
    }
    if ($expire_sec < (7 * 24 * 3600)) {
	$n = ($message) ?? ".\n" !! "";
	$message .= "$n SOA expire value ($expire) is less than 7 days";
    }
    if ($expire_sec > (183 * 24 * 3600)) {
	$n = ($message) ?? ".\n" !! "";
	$message .= "$n SOA expire value ($expire) is greater than 6 months";
    }
    if ($refresh_sec < (2 * $retry_sec)) {
	$n = ($message) ?? ".\n" !! "";
	$message .= "$n SOA refresh value is less than SOA retry "
		  . "* 2 [$refresh < ($retry * 2)]";
    }
    if (!$Verify_Mode && $RFC_2308 && $ttl_sec > 10800) {
	$n = ($message) ?? ".\n" !! "";
	$message .= "$n SOA negative cache value ($ttl) exceeds "
		  . "recommended maximum of 3 hours";
    }
    if ($message) {
	if ($Verify_Mode) {
	    print STDERR "\nWarning: found the following problematic ",
			 "SOA time interval(s):\n";
	} else {
	    print STDERR "Warning: the -o/+t option values generated ",
			 "the following message(s):\n";
	}
	print STDERR "$message.\n";
	return 1;
    } else {
	return 0;
    }
}


#
# Perform various consistency checks on zone data for each domain
# specified with the -V option.  The zone transfer data must first
# be processed by the "READ_RRs" subroutine before this one is called.
# Checks are made for the following conditions:
#   * SOA records containing time specifications with extreme values
#     (via the "CHECK_SOA_TIMERS" subroutine).
#   * NS, MX, and PTR records that point to CNAMEs or domain names
#     with no Address records or to nonexistent domain names (via the
#     "AUDIT_RRs" subroutine).
#   * CNAME records that point to nonexistent domain names, i.e.,
#     "dangling" CNAMEs (via the "AUDIT_RRs" subroutine).
#   * Zones with only one listed name server (violates RFC-1034),
#     NS RRsets with inconsistent TTL values (violates RFC-2181),
#     and NS RRs with missing glue (via the "AUDIT_RRs" subroutine).
#   * Lame delegations and name servers that are not running
#     or are unresponsive.  Accomplished with the `check_del'
#     program but only if delegation checking is not purposely
#     disabled by specifying the `-no-check-del' option.
#
# NOTE: In order to not adversely affect the amount of time that
#       `h2n' takes in its normal task of generating zone data,
#       future consistency checks should be limited to the -V option by
#       placing them into this subroutine instead of "AUDIT_RRs".
#
# Return values:
#   0 = no warnings
#   1 = warnings
#
sub CHECK_ZONE {
    my ($warning_status) = @_;
    my ($answer, $buffer, $debug_file, $del_batch, $first_answer, $fq_host);
    my ($host, $i, $mismatch, $n, $ns_data, $t, $ttl, $zone);
    my (%check_del_rr, @sorted_rrset, @zone_rrset);

    if ($BIND_Ver_Msg) {
	print STDERR "\nWarning: the name server supplying the zone data ",
		     "is running a version\n         of BIND that may be ",
		     "vulnerable to the following bug(s):\n",
		     "$BIND_Ver_Msg\n";
    }

    # First do some sanity checks on the SOA timer values and then call
    # the AUDIT_RRs() subroutine so that the %NSlist and %Ext_NS data
    # structures can be referenced.  These hashes are needed to prepare
    # an appropriate list of name servers for which proper delegation is
    # to be checked.
    # NOTE: The global "$Audit_Domain" variable that accommodates the processing
    #       of the root zone and is referenced by this subroutine is
    #       initialized by the AUDIT_RRs() subroutine.
    #
    $n = (AUDIT_RRs(CHECK_SOA_TIMERS())) ?? "" !! "\n";

    # Per RFC-1034, the NS RRsets that surround a zone cut are required
    # to be kept consistent.  We will now check for this by comparing
    # the NS RRset from the original DNS query (ostensibly above the zone
    # cut) to the NS RRset obtained from the zone transfer data, i.e.,
    # below the zone cut).  Our mileage may vary, however, because the
    # name server(s) that supplied the answer to the recursive DNS query
    # may have discovered and replaced the less credible NS RRset above
    # the zone cut with the authoritative (and thus more credible) NS
    # RRset from the zone itself.
    #
    # Note: As previously mentioned in the main program, a future
    #       version of `h2n' will use a query strategy that
    #       attempts to consistently obtain the NS RRset of the
    #       delegating parent zone (above the zone cut).  However,
    #       even this strategy may not succeed under the following
    #       conditions:
    #
    #         1. The name server is running BIND 4 or 8.
    #         2. The same name server is authoritative for the child
    #            zone as well as the parent zone, i.e., both sides
    #            of the zone cut.
    #
    #       In this case, the authoritative NS RRset of the child
    #       zone will always be returned.  This is due to the fact
    #       that BIND 4 and 8 name servers have just one database
    #       for storing data.  Both NS RRsets can't occupy the same
    #       space and so the authoritative data always wins.
    #       Another side-effect of this scenario is if the parent
    #       zone is being verified.  Missing glue will not be detected
    #       for the same reason.  It will always be "filled in" by the
    #       presence of the child zone's authoritative data.
    #       BIND 9 name servers, in contrast, have separate internal
    #       databases for each zone and, thus, exhibit none of these
    #       anomalies.
    #
    #
    ($ns_data = $NSowners{"$Domain."}) ~~ s/ \d+ (\S+)/$1 /g;
    $ns_data ~~ s/([^.]|\\[.]) /$1.$Audit_Domain /g;
    @zone_rrset = split(' ', $ns_data);
    @sorted_rrset = sort { $a cmp $b } @zone_rrset;
    @zone_rrset = @sorted_rrset;
    @sorted_rrset = sort { $a cmp $b } @DNS_RRset;
    @DNS_RRset = @sorted_rrset;
    $mismatch = 0;
    unless (scalar(@DNS_RRset) == scalar(@zone_rrset)) {
	$mismatch = 1;
    } else {
	for ($i = 0; $i < scalar(@DNS_RRset); $i++) {
	    next unless $DNS_RRset[$i] ne $zone_rrset[$i];
	    $mismatch = 1;
	    last;
	}
    }
    if ($mismatch) {
	print STDERR "${n}Warning: found inconsistent NS RRsets ",
		     "surrounding the zone boundary (RFC-1034):\n";
	$n = "";
	$t = (length(" $Domain.") <= 20) ?? 16 !! 24;
	for ($i = 0; $i < @DNS_RRset; $i++) {
	    if ($i == 0) {
		printf STDERR "%s\tIN NS\t%s\n", TAB(" $Domain.", $t),
			      $DNS_RRset[$i];
	    } else {
		printf STDERR "%s\tIN NS\t%s\n", TAB(" ", $t), $DNS_RRset[$i];
	    }
	}
	print STDERR " (non-authoritative)\n";
	print STDERR " ---------------------------- zone cut",
		     " ----------------------------\n";
	print STDERR " (  authoritative  )\n";
	for ($i = 0; $i < @zone_rrset; $i++) {
	    if ($i == 0) {
		printf STDERR "%s\tIN NS\t%s\n", TAB(' @', $t), $zone_rrset[$i];
	    } else {
		printf STDERR "%s\tIN NS\t%s\n", TAB(' ', $t), $zone_rrset[$i];
	    }
	}
    }

    if (keys(%NSowners) && $Verify_Delegations) {
	#
	# First, create the input file that will
	# be needed by the `check_del' program.
	#
	$del_batch = "$Debug_DIR/h2n-del.bat_$Data_Fname";
	unless (open(*DELBATCH, '>', $del_batch)) {
	    print STDERR "Couldn't create batch file for `check_del': $!\n";
	    print STDERR "Unable to verify name server delegations.\n";
	    $Verify_Delegations = 0;
	} else {
	    #
	    # Be thorough by also checking the NS RRset
	    # of the parent domain's delegation.
	    #
	    for ($i = 0; $i < @DNS_RRset; $i++) {
		print DELBATCH "$Domain.\t\t\tIN NS\t$DNS_RRset[$i]\n";
		$check_del_rr{"$Domain."} .= " $DNS_RRset[$i] ";
	    }
	    while (($zone, $buffer) = each %NSowners) {
		#
		# Cycle through each zone.
		#
		$zone = "$zone.$Audit_Domain" if $zone !~ /(?:^|[^\\])[.]$/;
		while ($buffer) {
		    #
		    # For each zone, cycle through each listed name server.
		    #
		    ($ttl, $host, $buffer) = split(' ', $buffer, 3);
		    if ($host ~~ /(?:^|[^\\])[.]$/) {
			$fq_host = $host;
		    } else {
			$fq_host = "$host.$Audit_Domain";
		    }
		    # Only check name servers that have a reasonable
		    # expectation of being found.
		    #
		    unless ((exists($NSlist{$host})
			     && $NSlist{$host} !~ /CNAME /)
			    ||
			    (exists($Ext_NS{$fq_host})
			     && $Ext_NS{$fq_host} !~ /(?:CNAME|SERVFAIL) /)) {
			#
			# Add the NS RR for `check_del' to process
			# but only if it is not already registered.
			#
			unless (exists($check_del_rr{$zone}) &&
				$check_del_rr{$zone} ~~ / $fq_host /) {
			    print DELBATCH "$zone\t\t$ttl\tIN NS\t$fq_host\n";
			    $check_del_rr{$zone} .= " $fq_host ";
			}
		    }
		}
	    }
	    close(*DELBATCH);
	}

	if ($Verify_Delegations && -s $del_batch) {
	    $first_answer = $answer = 1;
	    $debug_file = "$Debug_DIR/h2n-del.ans_$Data_Fname";
	    if ($Debug) {
		unless (open(*DEBUGOUT, '>', $debug_file)) {
		    print STDERR "Error opening `$debug_file': $!\n",
				 "Disabling the -debug option for the ",
				 "remainder of the program.\n";
		    $Debug = 0;
		}
	    }
	    #
	    # Use the `-F' (Fast) argument of `check_del'.
	    # Otherwise, you'll be sorry (and bored) when it
	    # trudges through a large list of unresponsive servers.
	    #
	    unless (open(*DELOUT, '-|',
			 "$Check_Del -F -v -f $del_batch 2>&1")) {
		print STDERR "Error running the `check_del' program: $!\n",
			     "Unable to verify NS delegations.\n";
	    } else {
		while (<DELOUT>) {
		    print DEBUGOUT $_ if $Debug;
		    next if /^$|^(?:Skipping|dropping|DD-like)[ ]|
			     [ ]is[ ]authoritative[ ]|
			     [ ](?:moved|put).*[ l]ist/x;
		    $answer = 0 if /^\s*\d/;	# Ignore everything past the
						# "proper" & "improper" summary.
		    #
		    # If this point is reached, then `check_del' has found
		    # something noteworthy to report.
		    #
		    if ($answer) {
			if ($first_answer) {
			    print STDERR "${n}Warning: verifying the NS ",
					 "delegations generated the ",
					 "following error(s):\n";
			    $n = "";
			    $first_answer = 0;
			}
			print STDERR " $_";
		    }
		}
		close(*DELOUT);
	    }
	    if ($Debug) {
		close(*DEBUGOUT);
	    } else {
		unlink($del_batch);
		#
		# Clean up any leftover debug file of check_del's output
		# from a prior run if the -debug option was specified.
		#
		unlink($debug_file) if -e $debug_file;
	    }
	}
    }

    if ($n) {
	$n = "Verification completed.\n";
	if ($BIND_Ver_Msg) {
	    $n = "\n$n";
	    $warning_status = 1;
	}
    }
    if ($warning_status || !$n) {
	print STDERR "$n\n";
	return 1;
    } else {
	return 0;
    }
}



sub VERIFY_ZONE {
    my ($V_opt_domain, $additional, $addr, $answer, $answer_section, $attempt);
    my ($authority, $data, $error, $expected_soa_count, $flags, $i, $ip);
    my ($match, $message, $n, $ns, $origin, $query_options, $separator);
    my ($status, $tmp, $version_buffer, $warning_status, $zone_data);
    my (@name_servers, @ns_local, @ns_net, @ns_other, @ns_subnet);

    #
    # Verify the zone data for each domain in the @V_Opt_Domains array.
    #
    # It only makes sense to do all this work if the "$Verbose" and "$Audit"
    # flags are enabled.  However, the user is free to set the level of
    # name checking by choosing the appropriate -I option which will then
    # set the "$RFC_1123" flag accordingly.  "Strict" name-checking will
    # be disabled, however, since the RFC-952 check for single-character
    # hostnames and/or aliases is only valid when processing a host table.
    #
    $Verbose = 1;
    $Audit = 1;
    $RFC_952 = 0;

    GET_LOCAL_NETINFO();		# for determining best net connectivity
    $separator = "";
    while (@V_Opt_Domains) {
	($V_opt_domain, $Recursion_Depth) = splice(@V_Opt_Domains, -2);
	#
	# Certain characters on the `h2n' command line like "<|>&()$?;'`"
	# must be escaped in order to make it past the shell and into this
	# program.  If any of these are present, the "$V_opt_domain" variable
	# will still keep them in order to make it past the shell once again
	# when the Perl system() function is called to issue the DiG AXFR
	# query a bit later in this subroutine.
	# Such escapes and shell operator characters, however, are poisonous
	# when trying to use them in a temporary filename.  To solve this
	# problem, we'll copy "$V_opt_domain" into "$Data_Fname" so that these
	# troublesome characters can be translated into something harmless.
	# We'll start by cleaning up the "$Data_Fname" variable just enough
	# so that we can display the actual domain name being verified.
	# NOTE 1: Leave "\$" and "\@" (and possibly "\(" and "\)" - see NOTE 2)
	#         escaped as an accurate presentation of what BIND itself
	#         displays when encountering these characters.
	#         In fact, "@" may appear unescaped on the command line
	#         since it is not a shell special character.  If that's
	#         the case, we'll insert an escape character before each
	#         unescaped "@" for the sake of robustness and consistency.
	# NOTE 2: The is an inconsistency in the way that BIND8 and early
	#         versions of BIND9 handle the "()" characters in the owner
	#         field of a domain name as opposed to BIND 9.1.2 and later
	#         versions.  BIND versions less than 9.1.2 will load the
	#         zone with or without preceding escapes and the corresponding
	#         versions of DiG will strip the escape characters that precede
	#         the "()" characters when it displays answers to a query.
	#         Conversely, BIND 9.1.2 and later will not load a zone with
	#         unescaped "()" characters in an owner field and the
	#         corresponding versions of DiG always include the escape
	#         characters in its displayed answers even when querying a
	#         name server that is running a BIND version earlier than 9.1.2.
	#
	$V_opt_domain ~~ s/([^\\])@/$1\\@/g;
	$Data_Fname = $V_opt_domain;
	if ($DiG_Version_Num >= 90102) {
	    $Data_Fname ~~ s/\\([<|>&\?;'`])/$1/g;
	} else {
	    $Data_Fname ~~ s/\\([<|>&\(\)\?;'`])/$1/g;
	}
	print STDOUT "$separator",
		     "\nVerifying zone data for domain `$Data_Fname':\n",
		     "Getting NS RRset...\n";
	#
	# Occasionally, a query is made for a domain's NS RRs and the
	# Additional Section of the response is incomplete.  One or more
	# subsequent queries, however, do return the IP address(es) that
	# that correspond with the NS RR(s) in the Answer Section.
	# The most likely scenario is an NS RRset where one or more NS RRs
	# point to name servers that are in a different Top-Level Domain
	# (TLD) than the zone itself.  Since the Internet root name servers
	# do not perform recursion and do not fetch glue, Address RRs that
	# are not on the same TLD server as the NS RRs will not appear in
	# the Additional Section of the response.  Once the local name server
	# has the NS RRset cached, successive recursive queries will cause
	# the desired Address RR(s) to appear in the Additional Section (but
	# *only* if the option `fetch-glue' is set to `yes' (see Note 3).
	# In anticipation of this possibility, we'll make up to five attempts
	# to get the Additional Section information that we expect to find.
	#
	# NOTE 1: Some name servers give out minimal answers, i.e., empty
	#         Authority and Additional Sections.  BIND 9 even has a
	#         configuration option to do this ("minimal-responses yes").
	#         The current strategy fails miserably in this circumstance.
	#
	# NOTE 2: If all of the NS records are misconfigured to point to
	#         CNAMEs instead of the canonical names (with A RRs), the
	#         Additional Section will always be empty since CNAMEs
	#         aren't "chased" when processing that section of the
	#         response.  The current strategy fails miserably in this
	#         circumstance.  See NOTE 3.
	#
	# NOTE 3: BIND 4 and 8 name servers have the `fetch-glue' option
	#         enabled by default.  BIND 9 name servers, however, have
	#         deprecated the glue-fetching option because it is now
	#         considered a bad idea.
	#         A future version of `h2n' will use a query strategy
	#         that tries to consistently get the delegation NS RRset
	#         from the parent zone (useful for later comparison with
	#         the authoritative NS RRset of the child zone).
	#         Also, explicit queries will be made for the Address RRs
	#         of the NS RRs.  Thus, the reliance on glue-fetching for
	#         supplying Address RRs in the Additional section will no
	#         longer be necessary.
	#
	$query_options = "+noques +noauthor +nostats +$DiG_Timeout "
		       . "+$DiG_Retries";
	@ns_local = @ns_subnet = @ns_net = @ns_other = ();
	$match = $error = 0;
	$attempt = 1;
	until ($match || $error || $attempt > 5) {
	    sleep 2 if $attempt > 1;
	    unless (open(*DIGOUT, '-|',
			 "$DiG $query_options $V_opt_domain NS 2>&1")) {
		print STDERR "Error running the `DiG' program: $!\n";
		GIVE_UP();
	    }
	    while (<DIGOUT>) {
		chop;
		next if /^$/;
		#
		# Whenever `h2n' calls the DiG utility, the pattern-matching
		# statements for processing the output are structured to be
		# compatible with the different formats generated by versions
		# 2.X, 8.X, and 9.X of DiG.
		#
		if (/^; <<>> DiG/) {
		    $status = "";
		    $answer = $answer_section = 0;
		    @DNS_RRset = ();
		} elsif (/^;.+(?:connection |no route|unreachable)/i) {
		    s/[^:]+:/ /;
		    $message = "DiG reported the following error:\n$_";
		    $error = 1;
		} elsif (/^;.+HEADER.+opcode: QUERY, status: ([^,]+)/) {
		    $status = $1;
		    if ($status ne 'NOERROR') {
			$message = "DiG reported the following status: $status";
			$error = 1;
			$status = "";
		    }
		} elsif ($status && /^;.+flags: (.*); QUE.*, ANS[^:]*: (\d+), AUTH[^:]*: (\d+), ADDIT[^:]*: (\d+)/i) {
		    $flags = $1;
		    $answer = $2;
		    $authority = $3;
		    $additional = $4;
		    if ($answer == 0) {
			if ($flags !~ /aa/ && $authority == 0
			    && $additional == 0) {
			    #
			    # We've probably queried a name server that is
			    # lame due to either bad delegation or it has
			    # invalidated a zone due to bad data (although
			    # SERVFAIL would be the expected response for
			    # the latter case).
			    #
			    $message = "DiG reported a failed query.  Perhaps "
				     . "a lame delegation was encountered.";
			} else {
			    #
			    # We've encountered an undelegated domain name.
			    #
			    $message = "DiG reported that no NS records exist.";
			}
			$error = 1;
			$status = "";
		    } elsif (($additional < $answer) && ($attempt < 5)) {
			#
			# Quit parsing this query and initiate another
			# recursive one in an attempt to get at least
			# as many name server IP addresses in the
			# Additional section as there are name servers
			# in the Answer section.
			#
			last;
		    } else {
			#
			# We either have at least as many IP addresses as
			# there are name servers in the Answer section or
			# we are on our last attempted query.  Continue
			# parsing the current response.
			#
			next;
		    }
		}
		next unless $status;
		if ($answer > 0) {
		    if (/^;; ANSWER/) {
			$answer_section = 1;
			next;
		    } elsif (/^;; ADDITIONAL/) {
			$answer_section = 0;
			next;
		    } elsif ($answer_section) {
			#
			# Store the answers so that the NS RRset of the
			# response can be compared to the NS RRset that
			# is actually contained in the domain's zone data.
			#
			s/.+\s+//;
			push(@DNS_RRset, lc($_));
			next;
		    }
		    # The Additional Section of the response has been reached.
		    # Assign the IP address to the proper network category.
		    #
		    next if !/[.]\s.*\sA\s+/;	# only deal with IPv4 A records
		    s/[.]\s.*\sA\s+/ /;
		    $tmp = $_;
		    $tmp ~~ s/.+ //;
		    $addr = pack('C4', split(/[.]/, $tmp, 4));
		    $match = 0;
		    foreach $tmp (@Our_Addrs) {
			next unless $addr eq $tmp;
			#
			# The localhost is authoritative for the domain.
			# Naturally, we'll try this IP address first.
			#
			push(@ns_local, $_);
			$match = 1;
			last;
		    }
		    next if $match;
		    for ($i = 0; $i < @Our_Netbits; $i++) {
			next unless ($addr & $Our_Netbits[$i]) eq $Our_Nets[$i];
			#
			# The IP address is on a local network.
			# Now see if it's on a local subnet.
			#
			if (($addr & $Our_Subnetmasks[$i])
			    eq $Our_Subnets[$i]) {
			    push(@ns_subnet, $_);
			} else {
			    push(@ns_net, $_);
			}
			$match = 1;
			last;
		    }
		    next if $match;
		    push(@ns_other, $_);
		    $match = 1;
		}
	    }
	    close(*DIGOUT);
	    $attempt++;
	}
	if ($error || !$match) {
	    unless ($error) {
		$message = "Failed to obtain any name server IP addresses.";
	    }
	    $answer = 0;
	    $error = 1;
	}
	# Finish the cleanup of "$Data_Fname" so that our temporary files
	# can be built without generating an error.  Obnoxious filename
	# characters will get translated into a harmless "%".  Escaped
	# whitespace will be converted to underscore characters and then
	# any remaining escapes will be eliminated.
	#
	for ($Data_Fname) {
	    s/\\([\$@\(\)])/$1/g;	  # unescape the "$@()" characters
	    s/[\/<|>&\[\(\)\$\?;'`]/%/g;
	    s/\\\s/_/g;
	    s/\\//g;
	    s/(\S+)[.]$/$1/;		  # trim last dot if not root zone
	}
	$zone_data = "$Debug_DIR/h2n-zone.data_$Data_Fname";
	if ($Debug && -s $zone_data) {
	    if ($error) {
		#
		# Even though we'll still proceed with the (re)verification
		# of the zone data left over from a previous run with the
		# `-debug' option, report the error that was encountered
		# when we tried to do a DNS query for the domain's NS RRset.
		# This will explain the subsequent warning message about
		# inconsistent NS RRsets which will surely come later.
		#
		print STDERR "$message\n",
			     "(proceeding anyway using zone data in ",
			     "`$zone_data')\n";
		$error = 0;
	    } else {
		print STDOUT "(using existing zone data in `$zone_data')\n";
	    }
	    $answer = $expected_soa_count = 1;
	    $BIND_Version = "";
	} elsif ($answer) {
	    print STDOUT "Transferring zone..";
	    $version_buffer = "";
	    $query_options = "+$DiG_Timeout +$DiG_Retries";
	    #
	    # Proactively create a generic error message
	    # just in case something unexpected happens.
	    #
	    $message = "All zone transfer attempts failed.";
	    $answer = 0;
	    $expected_soa_count = 2;
	    @name_servers = ();
	    push(@name_servers, @ns_local) if @ns_local;
	    push(@name_servers, @ns_subnet) if @ns_subnet;
	    push(@name_servers, @ns_net) if @ns_net;
	    push(@name_servers, @ns_other) if @ns_other;
	    foreach my $server (@name_servers) {
		($ns, $ip) = split(' ', $server, 2);
		print STDOUT ".";
		$version_buffer .= " ";
		$status = 0xffff & system("$DiG $query_options $V_opt_domain \\
					   axfr \@$ip > $zone_data 2>&1");
		#
		# If an error occurs, the message will be stored in a
		# variable and the next name server will be tried.
		# The loop is exited when a successful zone transfer is
		# made or there are no more name servers to try.  If the
		# transfer is unsuccessful, the last error message to be
		# stored will be the one that gets displayed.
		#
		if ($status == 0xff00) {
		    $message = "DiG command failed: $!";
		} elsif ($status > 0x80) {
		    $status >>= 8;
		    $message = "DiG command returned non-zero exit status: "
			     . "$status";
		} elsif ($status != 0) {
		    $message = "DiG command exited with ";
		    if ($status &   0x80) {
			$status &= ~0x80;
			$message .= "coredump from ";
		    }
		    $message .= "signal: $status";
		}
		#
		# Regardless of the system() function's exit status,
		# try to examine the last few lines of DiG's output.
		# We'll either get initial confirmation of a successful
		# zone transfer or, possibly, a more detailed message
		# explaining why the attempt(s) failed.
		# The definitive test of a successful zone transfer
		# will be the detection of the trailing SOA record
		# by the READ_RRs subroutine.
		#
		if (open(*ZONE_DATA, '-|', "tail", "-7", "$zone_data")) {
		    while (<ZONE_DATA>) {
			if (/^;; Received (\d+) answers? \(\d+ records?\)/ ||
			    /^;; XFR size:\s+(\d+) names?,\s+\d+ rrs?/i ||
			    /^;; XFR size:\s+(\d+) records?/i) {
			    #
			    # These lines are output by pre-9.X, 9.0.X, and
			    # 9.1.X-to-current versions of DiG, respectively,
			    # and usually indicate a successful zone transfer.
			    #
			    $answer = $1;
			    if ($answer == 0) {
				#
				# Pre-9.X versions of DiG return an answer
				# count of zero to indicate a disallowed
				# zone transfer.
				#
				$message = 'Transfer of zone data is '
					 . 'disallowed or unavailable.';
			    }
			    last;
			} elsif (/^; Transfer failed/) {
			    #
			    # This line is returned by 9.X versions of DiG
			    # when a zone transfer is either disallowed or
			    # unavailable.
			    #
			    $message = 'Transfer of zone data is '
				     . 'disallowed or unavailable.';
			    last;
			} elsif (/^;; [Cc]onnect/) {
			    #
			    # This pattern matches connection failures by all
			    # versions of DiG.
			    #
			    s/^;; *//;
			    s/[^:]+: //;
			    chop;
			    $message = ucfirst($_);
			    $message .= "." unless $message ~~ /[.]$/;
			    last;
			}
		    }
		    close(*ZONE_DATA);
		    last if $answer > 0;
		}
	    }
	    if ($answer > 0) {
		#
		# Report the name server from which the zone transfer was
		# obtained and make an inquiry about the version of BIND
		# it is running.
		#
		print STDOUT " (from `$ns' [$ip])\n";
		GET_BIND_VERSION($ip);
	    }
	}
	if ($answer == 0) {
	    $n = ($error) ?? "" !! "\n";
	    print STDERR "${n}$message\n",
			 "Unable to verify this domain.\n\n";
	    $separator = "";
	} else {
	    #
	    # Initialize the appropriate global variables that
	    # might be holding data from a previous pass.
	    #
	    # NOTE: Certain characters on the command line like "<|>&()?'`"
	    #       may have had to be escaped in order to make it past the
	    #       shell but require no escapes as part of a DNS domain name
	    #       (except for the previously-mentioned difference in the
	    #       way that "()" is handled by BIND/DiG versions 8 and 9).
	    #
	    #       Now that we're in a safer environment, remove the escapes
	    #       from "$V_opt_domain".  Otherwise, what we think is the
	    #       domain name won't match what's in the actual zone data file.
	    #
	    #       The "$Domain_Pattern" variable is another story.  Since
	    #       it represents "$V_opt_domain" as a matching Regular
	    #       Expression, we must make sure that any RE metacharacters
	    #       contained therein get escaped.
	    #
	    if ($DiG_Version_Num >= 90102) {
		$V_opt_domain ~~ s/\\([<|>&\?'`])/$1/g;
	    } else {
		$V_opt_domain ~~ s/\\([<|>&\(\)\?'`])/$1/g;
	    }
	    $Domain = $origin = $V_opt_domain;
	    $Domain ~~ s/[.]$//;
	    $Domain_Pattern = ($V_opt_domain ne '.') ?? ".$Domain" !! "";
	    $Domain_Pattern ~~ s/([.\|\\\$\^\+\[\(\)\?'`])/\\$1/g;
	    $SOA_Count = 0;
	    $RespHost = $RespUser = "";
	    $Refresh = $Retry = $Expire = $Ttl = "";
	    %RRowners = ();
	    %NSowners = ();
	    %NSlist = ();
	    %Ext_NS = ();
	    %Wildcards = ();
	    $Newline_Printed = 0;
	    if ($BIND_Version) {
		$version_buffer .="(NS BIND version: $BIND_Version)";
	    } else {
		$version_buffer = "";
	    }
	    print STDOUT "Parsing zone data...$version_buffer\n";
	    $warning_status = $Newline_Printed = READ_RRs($zone_data, $origin,
							  $origin, $origin, 0);
	    print STDERR "\n" while $Newline_Printed--;
	    if ($SOA_Count < $expected_soa_count) {
		if ($expected_soa_count == 2) {
		    print STDERR "Incomplete zone transfer detected - ",
				 "suppressing further action.\nUnable ",
				 "to verify this domain.\n\n";
		} else {
		    print STDERR "Missing SOA record from zone data - ",
				 "suppressing further action.\nUnable ",
				 "to verify this domain.\n\n";
		}
		$warning_status = 1;
	    } elsif (!exists($NSowners{$origin})) {
		print STDERR "No NS records found at zone top - ",
			     "suppressing further action.\nUnable ",
			     "to verify this domain.\n\n";
		$warning_status = 1;
	    } elsif ($Load_Status == 4) {
		#
		# Unbalanced quotes/parentheses prevented READ_RRs() from
		# completely reading the zone file.  The detailed error
		# message has already been printed.
		#
		print STDERR "Unable to verify this domain.\n\n";
		$warning_status = 1;
	    } else {
		$data = ($Query_External_Domains) ?? " and external" !! "";
		print STDOUT "Performing in-zone$data lookups...\n";
		$warning_status = CHECK_ZONE($warning_status);
	    }
	    if ($warning_status) {
		$separator = "<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<"
			   . ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>\n";
	    } else {
		print STDOUT "Domain verified with no detected ",
			     "improprieties!\n\n";
		$separator = "";
	    }
	}
	unlink($zone_data) unless $Debug;
    }
    return;
}



#
# Reverse the octets of a network specification or the labels of
# a domain name.  Only unescaped "." characters are recognized
# as octet/label delimiters.
#
sub REVERSE {
    my ($dotted_token) = @_;

    $dotted_token ~~ s/([^\\])[.]/$1 /g;
    return join('.', reverse(split(' ', $dotted_token)));
}




#
# Expand an IPv6 address to eight colon-delimited fields.
#
# Parameters #1:  An IPv6 address string, assumed to be syntactically valid.
#            #2:  'FULL'    : Fully expand the address to 32 hex digits.
#                 or
#                 'PARTIAL' : Expand the address but omit leading zeros.
# Return value: The expanded format of the address with lower-case hex digits.
#
sub EXPAND_IPv6 {
    my ($addr, $expand_level) = @_;
    my ($format, @binary_addr);

    if ($addr ~~ /::/) {

        my $colon_count;

        # Reconstitute the missing 16-bit zero field(s) of
        # the compressed address.
        #
        $colon_count = ($addr ~~ tr/:/:/);
        $colon_count-- if $addr ~~ /^:/;
        $colon_count-- if $addr ~~ /:$/;
        $addr ~~ s/::/':' x (9 - $colon_count)/e;
        1 while $addr ~~ s/::/:0:/g;
        $addr ~~ s/^:|:$//g;
    }
    if ($expand_level eq 'PARTIAL') {
	#
	# Remove any unnecessary leading zeros.
	# NOTE: Although the following regex will do the job:
	#
	#         $addr ~~ s/(^|:)0+([^:]+)/$1$2/g;
	#
	#       it suffers from exponentially slow backtracking.
	#       Luckily, this is Perl in which there's more than
	#       one way to do things.
	#
	$format = "%x:%x:%x:%x:%x:%x:%x:%x";
    } else {
	$format = "%04x:%04x:%04x:%04x:%04x:%04x:%04x:%04x";
    }
    @binary_addr = map(hex, split(/:/, $addr));
    $addr        = sprintf("$format", @binary_addr);
    return $addr;
}




#
# Reduce an IPv6 address to its most compressed format.
#
# Parameter:    An IPv6 address string; assumed to be syntactically valid.
# Return value: The fully-compressed format of the address.
#
sub COMPRESS_IPv6 {
    my ($addr) = @_;
    my ($contiguous_zero_fields, $field, $fields_to_compress);
    my (@char_addr, @candidate_fields);

    #
    # Although the IPv6 address may already be compressed, it could
    # be in way that is not consistent with the compression scheme
    # that is recommended by the latest proposed standard for the
    # presentation of human-friendly IPv6 addresses:
    #
    # http://tools.ietf.org/html/rfc5952
    #
    # For our purposes, the IPv6 reformatting scheme is:
    #
    #   * convert to lower case
    #   * suppress all leading zeroes
    #   * use "::" to shorten as much as possible
    #   * do _NOT_ use "::" to shorten just one 16-bit zero field
    #   * in the situation where there are disjoint occurences
    #     of an equal number of 16-bit zero fields, e.g.,
    #
    #       1:0:0:0:2:0:0:0
    #
    #     the first sequence of zero bits is shortened, e.g.,
    #
    #       1::2:0:0:0  _NOT_  1:0:0:0:2::
    #
    # To do this, we'll expand the address to its full eight-field
    # format but without any leading zeros and then put each field
    # into a character array so that the fields can be numbered
    # like so:
    #
    #   a:0:0:d:e:f:0:0
    #   ^ ^ ^ ^ ^ ^ ^ ^
    #   0 1 2 3 4 5 6 7
    #
    # Consecutive zero fields in the most significant portion
    # of the address (e.g., "12") will always sort before
    # those in the least significant fields (e.g., "67").
    #
    @char_addr = split(/:/, EXPAND_IPv6($addr, 'PARTIAL'));
    $contiguous_zero_fields = $fields_to_compress = '';
    @candidate_fields = ();
    for (my $i = 0; $i <= 7; $i++) {
	if ($char_addr[$i] eq '0') {
	    $contiguous_zero_fields .= "$i";
	} else {
	    if (length($contiguous_zero_fields) >= 2) {
		push(@candidate_fields, $contiguous_zero_fields);
	    }
	    $contiguous_zero_fields = '';
	}
    }
    if (length($contiguous_zero_fields) >= 2) {
	push(@candidate_fields, $contiguous_zero_fields);
    }

    if (@candidate_fields) {
	$fields_to_compress = $candidate_fields[0];
	if (@candidate_fields > 1
	    && ($candidate_fields[1] < $fields_to_compress)) {
	    $fields_to_compress = $candidate_fields[1];
	}
	if (@candidate_fields == 3
	    && ($candidate_fields[2] < $fields_to_compress)) {
	    #
	    # In an eight-field IPv6 address, there can be
	    # no more than three disjoint instances of fields
	    # with consecutive zeros.
	    #
	    $fields_to_compress = $candidate_fields[2];
	}
    }
    while (length($fields_to_compress)) {
	($field, $fields_to_compress) = split(//, $fields_to_compress, 2);
	$char_addr[$field] = '';
    }
    $addr = sprintf("%s:%s:%s:%s:%s:%s:%s:%s", @char_addr);
    $addr ~~ s/:::+/::/;
    return $addr;
}



sub GIVE_UP {

    print STDERR "I give up ... sorry.\n";
    exit(2);
}



#
# Subroutine to parse a list of `h2n' options and arguments thereof.
#
# It is first called in a scalar context by the READ_RCFILE subroutine
# to process any options that are found in a special configuration file.
# In this context, PARSE_ARGS will print a message for each warning or
# error it encounters but will not terminate `h2n' prematurely.
# After returning a count of printed messages to READ_RCFILE, `h2n'
# will terminate with an informational message about the configuration
# file if the message count is non-zero.
#
# If no error or warning messages were encountered by READ_RCFILE,
# PARSE_ARGS is called again, this time by the main program in a
# void context to process the actual command-line arguments.
# This allows for a logical way to dynamically override any option
# that may be in the `h2n' configuration file as a normal default.
# In the void context, the program will terminate upon encountering
# any hard error while processing a command-line option.
#
sub PARSE_ARGS {
    my @args = @_;
    #
    # The following two variables hold patterns for all the command-line
    # options that `h2n' recognizes.  By explicitly defining these
    # reserved tokens, the parser will be able to accept non-matching
    # tokens as option arguments which themselves may also begin with
    # a `-' or `+' character.
    #
    my $h2n_opts = "-[AaBbCcDdefHhIiLMmNnOoPpqrSsTtuVWwXyZz]|-v([:=].*)?|"
		 . "\\+([CcLmOSt]|o[ms])";
    my $verify_opts = "--?(no-?)?(check|verify)[_-]?del|"
		    . "--?(no-?)?debug([:=].*)?|"
		    . "--?(no-?)?recurs(e|ive|ion)([:=].*)?|"
		    . "--?(no-?)?(show|hide)-?single-?(ns|del(egation)s?)?|"
		    . "--?(no-?)?(show|hide)-?(dangling|nxdomain)-?cnames?|"
		    . "--?(no-?)?(show|hide)-?(cname|chained)-?(chain|cname)s?|"
		    . "--?(no-?)?query-?(ext(ernal)?)?-?(domains?|names?)?|"
		    . "--?glue(less)?-?(limit|levels?)?([:=].*)?|"
		    . "--?(?:[?]|hel?p?)";

    my %no_arg_opt = (
	'-A'                     => 0,
	'-P'                     => 0,
	'-X'                     => 0,
	'-q'                     => 0,
	'-r'                     => 0,
	'-w'                     => 0,
	'check-del'              => 0,
	'single-ns'              => 0,
	'chained-cnames'         => 0,
	'query-external-domains' => 0
    );

    my %arg_opt = (
	'-a' => 'at least one argument, a network number, is required',
	'-n' => 'at least one argument, a network number, is required',
	'-B' => 'the required boot/conf file pathname argument is missing',
	'-b' => "the `boot' file argument is missing",
	'-C' => 'must specify the name of a comment file as an argument',
	'-c' => 'required domain name argument is missing',
	'+C' => "the `conf' prepend file argument is missing",
	'+c' => "must specify a `conf' file and/or `mode=' argument(s)",
	'-d' => 'at least one argument, the domain name, must be specified',
	'-e' => 'required domain name argument is missing',
	'-f' => 'the required filename argument is missing',
	'-H' => 'must specify the name of a host file as an argument',
	'-h' => 'the zone master name server (SOA MNAME) is missing',
	'-i' => 'the SOA serial number is missing',
	'-L' => 'the max-filehandles argument is missing',
	'-m' => "the `MX-preference:MX-mailhost' argument pair is missing",
	'-N' => 'must specify /CIDRsize or subnetmask as an argument',
	'-o' => 'must specify an argument of one or more SOA time values',
	'-p' => 'required domain name argument is missing',
	'-S' => 'required DNS server name argument is missing',
	'-s' => 'required DNS server name argument is missing',
	'-T' => "must specify at least one of the following arguments:\n"
	      . "                      mode=M, RR=, and/or ALIAS=",
	'+t' => 'must specify at least a DEFAULT-TTL argument',
	'-u' => 'the zone contact mail address (SOA RNAME) is missing',
	'-V' => 'required domain name argument is missing',
	'-W' => 'the zone file directory name is missing',
	'-Z' => 'must specify at least one name server IP address',
	'-z' => 'must specify at least one name server IP address'
    );

    # Create a set of RRtypes that will be recognized as valid to add
    # to a forward-mapping zone's apex with the -T option.
    # NOTE: The RRs dedicated solely to DNSSEC (DNSKEY, NSEC, NSEC3,
    #       NSEC3PARAM, RRSIG, and NXT [obsolete]) are valid in a zone
    #       apex but should be added by a zone signing application such
    #       as the BIND9 dnssec-signzone(8) program instead of the -T option.
    #
    my $apex_rrtypes = "MX|A|PTR|AAAA|HINFO|RP|TXT|SRV|A6|NSAP|AFSDB|RT|ISDN|"
		     . "X25|PX|NAPTR|LOC|CERT|SIG|KEY|KX|DNAME|WKS|GPOS|APL";

    my ($already_warned, $alt_db_arg, $alt_db_file, $alt_spcl_arg);
    my ($alt_spcl_file, $argument, $arg2, $char, $cidr_size, $class_c_key);
    my ($comment, $continuation_line, $current_arg, $cwd, $data);
    my ($default_supernetting, $domain_arg, $error, $file, $first_ip, $flag);
    my ($formatted_template, $ip_range, $j, $last_ip, $last_char, $last_n_or_d);
    my ($lc_zone_name, $line_num, $message, $message_count, $net, $net_file);
    my ($next_arg, $octet1, $octets1_and_2, $octet_token, $open_paren_count);
    my ($open_quote, $option, $option_args_txt, $option_modifier);
    my ($option_value, $original_line, $original_option, $other_args, $overlap);
    my ($pattern, $preference, $previous_option, $ptr_arg, $ptr_map);
    my ($ptr_template, $rfc_2317_domain, $rdata, $rrtype, $skip_next_token);
    my ($spcl_file, $sub_class_c_key, $subnet, $subnet_key, $subnetmask);
    my ($supernet, $tmp, $tmp1, $tmp2, $tmp_master_ttl, $tmp_ttl, $token);
    my ($ttl, $zone_file, $zone_name);
    my (%allocated_octets, %duplicate, %e_opt_domain, %f_opt_file);
    my (%sub_class_c);
    my (@alt_spcl_files, @ctime, @insertion_args, @option_args);
    my (@option_history, @unbalanced_args);

    $cwd = getcwd();
    $last_n_or_d = $previous_option = "";
    $default_supernetting = $message_count = 0;
    @option_history = ();
    while (@args) {
	$option = $original_option = shift(@args);

	if ($Verbose) {
	    if ($option eq '-1') {
		print STDERR "Option `-1' is obsolete ... ignored.\n";
		$message_count++;
		next;
	    } elsif ($option eq '-F') {
		print STDERR "Option `-F' is now the default (and only) ",
			     "way ... ignored.\n";
		$message_count++;
		next;
	    } elsif ($option !~ /^(?:$h2n_opts)$/o
		     && $option !~ /^(?:$verify_opts)$/io) {
		if ($option ~~ /^[+-].+/) {
		    print STDERR "Unknown option `$option'; ignored.\n";
		} else {
		    print STDERR "Extraneous input `$option'; ignored.\n";
		}
		$message_count++;
		next;
	    }
	}

	if (@option_history) {
	    $previous_option = $option_history[-1];    # -1 = last array element
	    if ($previous_option ~~ /^(?:[+](?:om|os))|-S$/
		&& $option !~ /^(?:[+](?:om|os))|-S$/) {
		#
		# Re-initialize "$last_n_or_d" which holds the "db"
		# file information from the last -d option or the
		# accumulated "db" files from each of the preceding
		# -n options.
		#
		$last_n_or_d = "-n" unless ($previous_option ~~ /^[+](?:om|os)$/
					    && $last_n_or_d eq "");
	    }
	}
	push(@option_history, $option);

	if ($option ~~ /^(?:$verify_opts)$/io) {
	    $option_modifier = ($option ~~ /^--?no/i) ?? 'no' !! "";
	    if ($option ~~ /^--?(?:no-?)?(show|hide)/i) {
		$option_modifier .= "-" . lc($1);
	    }
	    $option_value = "";
	    if ($original_option ~~ /^--?(?:no-?)?(?:check|verify)[_-]?del$/i) {
		$option = 'check-del';
	    } elsif ($original_option ~~ /^--?(?:no-?)?debug([:=].*)?$/i) {
		$option       = 'debug';
		$option_value = $1 if defined($1);
	    } elsif ($original_option ~~ /^--?(?:no-?)?recurs(?:e|ive|ion)
					  ([:=].*)?$/ix) {
		$option       = 'recurse';
		$option_value = $1 if defined($1);
	    } elsif ($original_option ~~ /^--?(?:no-?)?(?:show|hide)-?single-?
					  (?:ns|del(?:egation)s?)?$/ix) {
		$option = 'single-ns';
	    } elsif ($original_option ~~ /^--?(?:no-?)?(?:show|hide)-?
					  (?:dangling|nxdomain)-?cnames?$/ix) {
		$option = 'dangling-cnames';
	    } elsif ($original_option ~~ /^--?(?:no-?)?(?:show|hide)-?
					  (?:cname|chained)-?
					  (?:chain|cname)s?$/ix) {
		$option = 'chained-cnames';
	    } elsif ($original_option ~~ /^--?(?:no-?)?query-?
					  (?:ext(?:ernal)?)?-?
					  (?:domains?|names?)?$/ix) {
		$option = 'query-external-domains';
	    } elsif ($original_option ~~ /^--?glue(?:less)?-?(?:limit|levels?)?
					  ([:=].*)?$/ix) {
		$option       = 'glue-level';
		$option_value = $1 if defined($1);
	    } else {
		$option = 'help';
	    }
	    $option_value ~~ s/^[:=]// if $option_value;
	}

	@option_args = ();
	while (@args && ($next_arg = $args[0]) !~ /^(?:$h2n_opts)$/o
		     &&  $next_arg             !~ /^(?:$verify_opts)$/io) {
	    push(@option_args,   $next_arg);
	    shift(@args);
	}

	if (exists($arg_opt{$option}) && !@option_args) {
	    print STDERR "Improper `$original_option' option; ",
			 "$arg_opt{$option}.\n";
	    GIVE_UP() unless defined wantarray;
	    $message_count++;
	    next;
	}

	if (exists($no_arg_opt{$option}) && @option_args && $Verbose) {
	    $option_args_txt = join(" ", @option_args);
	    print STDERR "Warning: the `$original_option' option takes no ",
			 "argument.\n",
			 "         Ignoring argument(s) `$option_args_txt'.\n";
	     $message_count++;
	     @option_args = ();
	}

	if ($option eq "-A") {
	    $Do_CNAME = 0;

	} elsif ($option eq "-a" || $option eq "-n") {
	    $last_n_or_d = "-n" if ($option eq "-n" && $last_n_or_d eq "");
	    while (@option_args) {
		$argument = shift(@option_args);
		if ($argument ~~ /^(?:mode|domain|ptr-owner|db|spcl)=/i) {
		    if ($argument ~~ /^mode=/i) {
			$argument ~~ s/=.*/=/;
			print STDERR "Improper $option option.\nA network ",
				     "number must precede `$argument'.\n";
                    } elsif ($option eq "-n") {
			print STDERR "Improper -n option.\nA network ",
				     "number must precede `$argument'.\n";
		    } else {
			print STDERR "Improper -a option.\nThe `$argument' ",
				     "domain argument is not allowed.\n";
		    }
		    GIVE_UP() unless defined wantarray;
		    $message_count++;
		    last;
		}
		if ($argument ~~ /:/) {
		    ($net, $subnetmask) = split(/:/, $argument, 2);
		    $cidr_size = undef;
		} elsif ($argument ~~ /\//) {
		    ($net, $cidr_size) = split('/', $argument, 2);
		    $subnetmask = undef;
		} else {
		    $net = $argument;
		    $subnetmask = $Defsubnetmask;
		    $cidr_size = undef;
		}
		$error = CHECK_NET(\$net, \$cidr_size, \$subnetmask);
		if ($error) {
		    print STDERR "Improper $option option ",
				 "($option $argument):\n$error";
		    GIVE_UP() unless defined wantarray;
		    $message_count++;
		    last;
		} elsif ($cidr_size < 8) {
		    print STDERR "Improper $option option ",
				 "($option $argument).\nOnly network ",
				 "sizes /8 to /32 are supported.\n";
		    GIVE_UP() unless defined wantarray;
		    $message_count++;
		    last;
		}
		# Gather any `mode=', `domain=', `ptr-owner=', `db=', and/or
		# `spcl=' argument(s) that may be present after first setting
		# the appropriate default values in case the argument(s) are
		# absent.
		#
		$supernet = $domain_arg = $rfc_2317_domain = $ptr_arg
			  = $ptr_template = $alt_db_arg = $alt_db_file
			  = $alt_spcl_arg = $alt_spcl_file = $other_args = "";
		$alt_spcl_file = "";
		while (@option_args &&
		       ((($next_arg = $option_args[0]) ~~ /^mode=/i
						     && !$supernet)   ||
			($next_arg ~~ /^domain=/i    && !$domain_arg) ||
			($next_arg ~~ /^ptr-owner=/i && !$ptr_arg)    ||
			($next_arg ~~ /^db=/i        && !$alt_db_arg) ||
			($next_arg ~~ /^spcl=/i      && !$alt_spcl_arg))) {
		    $arg2 = shift(@option_args);
		    if ($arg2 ~~ /^mode=/i) {
			$supernet = $arg2;
		    } elsif ($arg2 ~~ /^domain=/i) {
			$domain_arg = $arg2;
		    } elsif ($arg2 ~~ /^ptr-owner=/i) {
			$ptr_arg = $arg2;
		    } elsif ($arg2 ~~ /^db=/i) {
			$alt_db_arg = $arg2;
		    } else {
			$alt_spcl_arg = $arg2;
		    }
		}
		if ($supernet) {
		    unless ($supernet ~~ /^mode=S$/i) {
			print STDERR "Improper `$supernet' argument in ",
				     "$option option.\nThe component of ",
				     "a valid `mode=' value must be `S'.\n";
			GIVE_UP() unless defined wantarray;
			$message_count++;
			last;
		    } elsif ($cidr_size >= 25) {
			print STDERR "Improper $option option ",
				     "($option $argument).\nThe `$supernet' ",
				     "argument is for CIDR sizes 8 to 24; ",
				     "ignored.\n";
			$message_count++;
			$supernet = "";
		    } else {
			$supernet = "S ";
		    }
		} else {
		    $supernet = "S " if ($default_supernetting
					 && $cidr_size <= 24);
		}
		$Supernetting_Enabled = 1 if $supernet;
		if ($domain_arg) {
		    #
		    # Check to see if the domain name is not one that
		    # fits the pattern of a standard delegation in the
		    # `arpa.' zone, i.e., that of a /8, /16, or /24
		    # network.  First, however, clean up the domain
		    # name as follows:
		    #
		    #   1. Remove any redundant escape characters and
		    #      any trailing root zone (".") characters.
		    #   2. Remove any escapes that may have been
		    #      necessary to get the special characters
		    #      "<|>&()$?;'`" past the shell.
		    #   3. Escape any unescaped "@" character to be
		    #      consistent with BIND when it encounters
		    #      "@" as a literal character in a domain name.
		    #
		    ($rfc_2317_domain = $domain_arg) ~~ s/^domain=//i;
		    1 while $rfc_2317_domain ~~ s/\\\\/\\/g;
		    $rfc_2317_domain ~~ s/([^\\])[.]+$/$1/;
		    $rfc_2317_domain ~~ s/\\([<|>&\(\)\?;'`])/$1/g;
		    $rfc_2317_domain ~~ s/([^\\])@/$1\\@/g;
		    $error = 0;
		    if (($option eq "-n" && $cidr_size <= 24)
			|| $option eq "-a") {
			print STDERR "Improper -n option (-n $argument).\n",
				     "The `$domain_arg' domain argument is ",
				     "for CIDR sizes 25 to 32; ignored.\n"
			    if $option eq "-n";
			print STDERR "Improper -a option (-a $argument).\n",
				     "The `$domain_arg' domain argument is ",
				     "meaningless; ignored.\n"
			    if $option eq "-a";
			$message_count++;
			$rfc_2317_domain = "";
		    } elsif ($rfc_2317_domain
			     && CHECK_NAME($rfc_2317_domain, 'SOA')) {
			print STDERR "Improper `domain=' argument ",
				     "(-n $argument  $domain_arg).\n",
				     "It is not a valid domain name.\n";
			$error = 1;
		    } elsif ($rfc_2317_domain ~~ /^(?:(?:\d+[.]){1,3})?
						  in-addr.arpa$/ix) {
			print STDERR "Improper `domain=' argument ",
				     "(-n $argument  $domain_arg).\n",
				     "It conflicts with the hierarchy of ",
				     "parent networks under the ARPA zone.\n";
			$error = 1;
		    } elsif ($cidr_size == 32
			     && $rfc_2317_domain ~~ /^(?:\d+[.]){4}
						     in-addr.arpa$/ix
			     && lc($rfc_2317_domain) ne
				REVERSE($net) . ".in-addr.arpa") {
			print STDERR "Improper `domain=' argument ",
				     "(-n $argument  $domain_arg).\n",
				     "It represents a different /32 ",
				     "network under the ARPA zone.\n";
			$error = 1;
		    } elsif ($rfc_2317_domain !~ /(?:(?:\d+[.]){3})
						  in-addr.arpa$/ix
			     && !$Domain) {
			#
			# The forward-mapping domain must be known in advance
			# so that references to it by the `domain=' argument
			# can be recognized and correctly processed.
			#
			print STDERR "Improper `domain=' argument ",
				     "(-n $argument  $domain_arg).\n",
				     "It cannot be properly processed without ",
				     "first specifying the -d option.\n";
			$error = 1;
		    }
		    if ($error) {
			GIVE_UP() unless defined wantarray;
			$message_count++;
			last;
		    }
		}
		if ($ptr_arg) {
		    #
		    # Check the PTR template for basic syntax and pay
		    # special attention to contexts which require or
		    # disallow a top-of-zone PTR record, e.g.,
		    #
		    #   $ORIGIN d.c.b.a.in-addr.arpa.
		    #   @  IN SOA  . . ( serial refresh retry expiry minimum )
		    #      IN NS   nameserver1.
		    #      IN NS   nameserver2.
		    #      IN PTR  some.domain.name.
		    #
		    # First, however, clean up the PTR owner name template
		    # as follows:
		    #
		    #   1. Remove any redundant escape characters.
		    #   2. Make sure to detect an empty pair of single
		    #      or double quotes (escaped or unescaped) and
		    #      change them to a pair of unescaped single
		    #      quote characters.  This is the syntax for
		    #      requesting a top-of-zone PTR record.
		    # NOTE: Since the literal "$" and "'" characters
		    #       are valid in the owner name field of a PTR
		    #       record, the cleaned-up copy of "$ptr_template"
		    #       is sufficient for basic DNS domain name testing
		    #       with the CHECK_NAME subroutine.
		    #
		    ($ptr_template = $ptr_arg) ~~ s/^ptr-owner=//i;
		    1 while $ptr_template ~~ s/\\\\/\\/g;
		    if ($ptr_template ~~ /^(?:[\\]?\'){2}$/
			|| $ptr_template ~~ /^(?:[\\]?\"){2}$/) {
			$ptr_template = "''";
		    }
		    $error = 0;
		    if (($option eq "-n" && $cidr_size <= 24)
			|| $option eq "-a") {
			print STDERR "Improper -n option (-n $argument).\n",
				     "The `$ptr_arg' domain argument is for ",
				     "CIDR sizes 25 to 32; ignored.\n"
			     if $option eq "-n";
			print STDERR "Improper -a option (-a $argument).\n",
				     "The `$ptr_arg' domain argument is ",
				     "meaningless; ignored.\n"
			    if $option eq "-a";
			$message_count++;
			$ptr_template = "";
		    } elsif (CHECK_NAME($ptr_template, 'PTR')) {
			print STDERR "Improper `ptr-owner=' argument ",
				     "(-n $argument  $ptr_arg).\nIt would ",
				     "create an invalid DNS domain name.\n";
			if ($ptr_template ~~ /[.]$/) {
			    print STDERR "The `ptr-owner' argument must be ",
					 "specified in domain-relative format.",
					 "\n";
			}
			$error = 1;
		    } elsif ($ptr_template ~~ /(?:^|[^\\])\$[^1-4]/) {
			print STDERR "Improper `ptr-owner=' argument ",
				     "(-n $argument  $ptr_arg).\nValid octet ",
				     "substitution tokens are \$1, \$2, \$3, ",
				     "and \$4.\n";
			$error = 1;
		    } elsif ($cidr_size != 32 && $ptr_template eq "''") {
			print STDERR "Improper `ptr-owner=' argument ",
				     "(-n $argument  $ptr_arg).\nA ",
				     "top-of-zone PTR record is only ",
				     "valid for a /32 network.\n";
			$error = 1;
		    } elsif ($cidr_size == 32 && $ptr_template ne "''"
			     && (!$rfc_2317_domain
				 || $rfc_2317_domain ~~ /^(?:\d+[.]){4}
							 in-addr.arpa$/ix)) {
			$tmp1 = ($rfc_2317_domain) ?? "specified" !! "default";
			$tmp2 = REVERSE($net) . ".in-addr.arpa";
			print STDERR "Improper `ptr-owner=' argument ",
				     "(-n $argument  $ptr_arg).\nThe $tmp1 ",
				     "domain ($tmp2) for this network ",
				     "requires a\ntop-of-zone PTR record, ",
				     "i.e., omit the `ptr-owner=' argument ",
				     "or set it to \"''\".\n";
			$error = 1;
		    } elsif ($ptr_template !~ /(?:^''$|(?:^|[^\\])\$4)/) {
			print STDERR "Improper `ptr-owner=' argument ",
				     "(-n $argument  $ptr_arg).\nThe `\$4' ",
				     "token (representing the rightmost octet ",
				     "of an IP address) must always\nbe ",
				     "present for creating the owner names ",
				     "of non-top-of-zone PTR records.\n";
			$error = 1;
		    } elsif ($ptr_template ~~ /^\*[.]/) {
			if ($cidr_size == 32) {
			    $error = "wildcard PTR record";
			} else {
			    $error = "set of wildcard PTR records";
			}
			print STDERR "Improper `ptr-owner=' argument ",
				     "(-n $argument  $ptr_arg).\nIt would ",
				     "create an ambiguous $error.\n";
			$error = 1;
		    }
		    if ($error) {
			GIVE_UP() unless defined wantarray;
			$message_count++;
			last;
		    } elsif ($ptr_template) {
			#
			# Do a character-by-character scan of the template
			# while looking backwards and forwards for IP address
			# octet tokens, non-printing characters, and whether
			# the current context is escaped or not.
			# The end product will be used as the replacement text
			# in a `s///' substitution operator for mapping an IP
			# address into its appropriate PTR record.  For example,
			# given an IP address of 156.153.254.81, say that we
			# want to construct the PTR record for the corresponding
			# class-B zone (153.156.in-addr.arpa).  The relative
			# owner name of the record needs to be `81.254'.
			# The Perl statements for doing this are:
			#
			#  $addr = "156.153.254.81";
			#  $addr ~~ s/(\d+)[.](\d+)[.](\d+)[.](\d+)/$4.$3/;
			#  $addr equals "81.254".
			#
			# This does *not* work, however:
			#
			#  $addr = "156.153.254.81";
			#  $template = "\$4.\$3";
			#  $addr ~~ s/(\d+)[.](\d+)[.](\d+)[.](\d+)/$template/;
			#  $addr equals "$4.$3".
			#
			# The contents of "$template" were literally substituted
			# for the matching pattern of "$addr".  The trick is to
			# use the `eval' modifier (/e) to evaluate the contents
			# of "$template" as an expression first.  The results
			# are then used as the substitution's replacement text.
			# Actually, it takes two `eval' modifiers (/ee) to get
			# the job done.  The first `eval' interpolates the
			# contents of "$template" and identifies the context of
			# "$3" and "$4" as capture variables.  In other words,
			# the replacement text is translated and staged.  The
			# second `eval' substitutes the captured text in "$3"
			# and "$4" and evaluates the resulting replacement
			# string in its entirety as a Perl expression.
			#
			# $addr = "156.153.254.81";
			# $template = "\$4.\$3";
			# $addr ~~ s/(\d+)[.](\d+)[.](\d+)[.](\d+)/$template/ee;
			# $addr equals "81254".
			#
			# What happened here was that "81" was substituted into
			# "$4" and "254" was substituted into "$3".  The "."
			# character, however, was evaluated as a concatenation
			# operator and thus the results were squashed together.
			# If the "$template" variable contained this instead:
			#
			#  $4 . '.' . $3
			#
			# the proper results would have been achieved (81.254).
			#
			# The following scan of "$ptr_template" will insert the
			# necessary quotes and concatenation operators to
			# achieve the desired results.
			# NOTE 1: Single quotes are used to surround non-token
			#         text to avoid the accidental interpolation
			#         of an `h2n' symbol name which may
			#         coincidentally exist.
			# NOTE 2: If "$ptr_template" contains the special value
			#         of "''", a short-circuit mechanism prevents
			#         it from being erroneously processed.
			#
			if ($ptr_template ~~ /^\$\d/) {
			    $formatted_template = "";
			    $open_quote = 0;
			} else {
			    $formatted_template = "'";
			    $open_quote = 1;
			}
			$last_char = "";
			$ptr_template = "" if $ptr_template eq "''";
			while (length($ptr_template)) {
			    if ($ptr_template ~~ /^\$(\d)/
				&& $last_char ne "\\") {
				$octet_token = $1;
				$formatted_template .= "'." if $open_quote;
				$formatted_template .= "\$$octet_token";
				$last_char = $octet_token;
				$ptr_template ~~ s/^..//;
				$open_quote = 0;
			    } else {
				unless ($open_quote) {
				    #
				    # There are one or more characters still
				    # left in the template after the $[1-4]
				    # octet token that was just processed in
				    # the previous iteration.
				    #
				    $formatted_template .= ".'";
				    $last_char = "";
				    $open_quote = 1;
				}
				($char,
				 $ptr_template) = split(//, $ptr_template, 2);
				if (ord($char) <= 32) {
				    #
				    # Create the escaped three-digit decimal
				    # representation of the non-printing ASCII
				    # character that's compatible with BIND.
				    #
				    $char = "0" . ord($char);
				    $char = "\\$char" if $last_char ne "\\";
				} elsif ($char ~~ /^(?:@|\"|\')$/
					 && $last_char ne "\\") {
				    $char = "\\$char";
				}
				$formatted_template .= $char;
				($last_char = $char) ~~ s/.*(.)$/$1/;
			    }
			}
			$formatted_template .= "'" if $open_quote;
			$ptr_template = $formatted_template;
		    }
		}
		$error = 0;
		if ($alt_db_arg) {
		    ($alt_db_file = $alt_db_arg) ~~ s/^db=//i;
		    unless ($Domain) {
			#
			# The forward-mapping domain must be known in advance
			# so that references to its DB file specification by
			# the `db=' argument of the -n option can be recognized
			# as a conflicting error.
			#
			print STDERR "Improper `db=' argument ",
				     "(-n $argument  $alt_db_arg).\n",
				     "It cannot be properly processed without ",
				     "first specifying the -d option.\n";
			$error = 1;
		    } elsif ($alt_db_file eq $Domainfile) {
			if ($cidr_size >= 25) {
			    print STDERR "Improper `db=' argument ",
					 "(-n $argument  $alt_db_arg).\n",
					 "Use the `domain=$Domain' argument ",
					 "instead to write PTR\n",
					 "records to the forward-mapping zone ",
					 "data file of the -d option.\n";
			} else {
			    print STDERR "Improper `db=' argument ",
					 "(-n $argument  $alt_db_arg).\n",
					 "Zone data for network sizes /8 to ",
					 "/24 can not be written to\n",
					 "the same forward-mapping zone data ",
					 "file of the -d option.\n";
			}
			$error = 1;
		    } else {
			1 while $alt_db_file ~~ s/\/\//\//g;
			$alt_db_file ~~ s/^[.]\///;
			$alt_db_file ~~ s/^[.]+$//;
			unless ($alt_db_file) {
			    print STDERR "Improper `$alt_db_arg' argument in ",
					 "-n option.\nA valid filename must ",
					 "be specified.\n";
			    $error = 1;
			} elsif ($alt_db_file ~~ /\//) {
			    print STDERR "Improper `$alt_db_arg' argument in ",
					 "-n option.\nNo pathname is allowed ",
					 "in the alternate DB file ",
					 "specification.\n",
					 "Use the -W option to specify an ",
					 "alternate directory for DB files.\n";
			    $error = 1;
			}
		    }
		    if ($error) {
			GIVE_UP() unless defined wantarray;
			$message_count++;
			last;
		    }
		    $other_args = "  $alt_db_arg";
		}
		if ($alt_spcl_arg) {
		    ($alt_spcl_file = $alt_spcl_arg) ~~ s/^spcl=//i;
		    1 while $alt_spcl_file ~~ s/\/\//\//g;
		    $alt_spcl_file ~~ s/^[.]\///;
		    $alt_spcl_file ~~ s/^[.]+$//;
		    unless ($alt_spcl_file) {
			print STDERR "Improper `$alt_spcl_arg' argument in ",
				     "-n option.\nA valid filename must be ",
				     "specified.\n";
			$error = 1;
		    } elsif ($alt_spcl_file ~~ /\//) {
			print STDERR "Improper `$alt_spcl_arg' argument in ",
				     "-n option.\nNo pathname is allowed in ",
				     "the `spcl' \$INCLUDE file specification.",
				     "\n",
				     "Use the -W option to specify an ",
				     "alternate directory for `spcl' files.\n";
			$error = 1;
		    }
		    if ($error) {
			GIVE_UP() unless defined wantarray;
			$message_count++;
			last;
		    }
		    $other_args .= "  $alt_spcl_arg";
		    #
		    # NOTE: The validation check of "$alt_spcl_file" is
		    #       deferred until the complete list of submitted
		    #       options has been processed.  Once the status
		    #       of the -W option is known, the validation of
		    #       the `spcl=' argument can be made.
		}

		# Now that the arguments have been vetted for proper syntax,
		# it's time to analyze the address space specifications to
		# see if there are any conflicts.
		#
		$overlap = "";
		$already_warned = $error = 0;
		foreach $subnet (SUBNETS($net, $cidr_size)) {
		    ($subnet_key, $ip_range) = split(/:/, $subnet, 2);
		    #
		    # For networks with a CIDR size <= 24, each constituent
		    # class-A, class-B, or class-C subnet serves as an index
		    # key into the %Net_Ranges hash.  The hash value is either
		    # a file-descriptor typeglob for a `-n' option or the null
		    # string for `-a', i.e.,
		    #
		    #  -n: $Net_Ranges{"N"}     = "*main::DB.N"     (/8)
		    #  -a: $Net_Ranges{"N"}     = ""                (/8)
		    #  -n: $Net_Ranges{"N.N"}   = "*main::DB.N.N"   (/9  to /16)
		    #  -a: $Net_Ranges{"N.N"}   = ""                (/9  to /16)
		    #  -n: $Net_Ranges{"N.N.N"} = "*main::DB.N.N.N" (/17 to /24)
		    #  -a: $Net_Ranges{"N.N.N"} = "";		    (/17 to /24)
		    #
		    # For networks with a CIDR size >= 25, the class-C supernet
		    # plus an appended ".X" string serves as the hash key index
		    # with a space-separated list of non-overlapping IP address
		    # ranges as the hash value.  The distinction between a `-n'
		    # or `-a' network is made by concatenating each IP-range to
		    # the class-C supernet to create the unique key, i.e.,
		    #
		    #  -n/-a: $Net_Ranges{"N.N.N.X"} = "IP-range IP-range ..."
		    #     -n: $Net_Ranges{"N.N.N.IP-range"} = "*main::DB.zone"
		    #     -a: $Net_Ranges{"N.N.N.IP-range"} = "";
		    #
		    # NOTE: By default, each non-overlapping sub-class-C
		    #       network within a class-C supernet is assigned
		    #       to a unique domain name.  However, since the
		    #       last octet of each such network address is
		    #       unique within the supernet (due to `$4' being
		    #       present in the PTR template), there's nothing
		    #       to prohibit these sub-class-C networks from
		    #       being combined into one "super-domain", i.e.,
		    #       sharing the same "domain=" argument.
		    #
		    #####
		    #
		    # The first thing we need to do is to check for the
		    # following network overlap conditions:
		    #
		    #   1.  Any overlap between networks of a different
		    #       class (A, B, C, or sub-C) will be reported
		    #       as a fatal error unless supernetting is in
		    #       effect (+S global option or `mode=S' argument
		    #       to -n/-a option) when the larger network
		    #       is declared with -n/-a.
		    #
		    #   2.  Overlaps between networks of the same class
		    #       (A, B, or C) will be let off with a warning.
		    #       Overlaps between sub-class-C networks will
		    #       always be reported as a fatal error, however.
		    #
		    #   3.  Intra-class A, B, or C overlaps (#2 above)
		    #       will be reported as a fatal error if the
		    #       specified option (-n/-a) is inconsistent.
		    #
		    # In conjunction with the %Net_Ranges hash described
		    # previously, the %allocated_octets hash will keep
		    # track of networks per the following example:
		    #
		    #   -a 192.168.15/24
		    #   $Net_Ranges{"192.168.15"} = "";
		    #   $tmp = "192.168.15 -a 192.168.15/24";
		    #   $allocated_octets{"192"}        = $tmp;
		    #   $allocated_octets{"192.168"}    = $tmp;
		    #   $allocated_octets{"192.168.15"} = $tmp;
		    #
		    # Subsequent attempts to process the following options:
		    #
		    #   -a 192/8
		    #   -a 192.168/16
		    #
		    # will fail because the octets would already be registered
		    # as keys in the %allocated_octets hash with a hash value
		    # pointing to a class-C network (192.168.15) as the
		    # registrant.  The remaining fields of the hash value
		    # ("-a 192.168.15/24") reference the original option for
		    # generating a descriptive error message.
		    #
		    # However, if supernetting is specified globally with the
		    # +S option or selectively by adding the `mode=S' argument
		    # to a -n/-a option, e.g.,
		    #
		    #   -a 192/8 mode=S
		    #   +S
		    #   -a 192.168/16
		    #
		    # then no error will be generated when a network overlaps
		    # with another of a larger class that has been declared to
		    # be a supernet.
		    #
		    if ($cidr_size == 8) {
			if (exists($allocated_octets{$subnet_key})) {
			    #
			    # Either a duplicate class A network exists or
			    # there's an overlap with an existing class B
			    # and/or class C network.
			    #
			    $overlap = $allocated_octets{$subnet_key};
			    if ($overlap !~ /^$subnet_key /) {
				#
				# An overlapping class B and/or class C and/or
				# one or more sub-class-C network(s) exist(s).
				#
				if ($supernet) {
				    $overlap = "";
				} else {
				    $error = 1;
				}
			    } elsif ($overlap !~ /\S+ $option /) {
				#
				# The duplicate class A network specification
				# is ambiguous because one is a -a option and
				# another is a -n option.
				#
				$error = 3;
			    }
			}
			unless ($overlap) {
			    $Net_Ranges{$subnet_key} = "";
			    $allocated_octets{$subnet_key} =
				"$subnet_key $supernet$option $argument";
			}
		    } elsif ($cidr_size <= 16) {
			($octet1 = $subnet_key) ~~ s/[.].+//;
			if (exists($allocated_octets{$subnet_key})) {
			    $overlap = $allocated_octets{$subnet_key};
			    if ($overlap !~ /^$subnet_key /) {
				#
				# An overlapping class C or one or more
				# sub-class-C network(s) exist(s).
				#
				if ($supernet) {
				    $overlap = "";
				} else {
				    $error = 1;
				}
			    } elsif ($overlap !~ /\S+ $option /) {
				#
				# The duplicate class B network specification
				# is ambiguous because one is a -a option and
				# another is a -n option.
				#
				$error = 3;
			    }
			} elsif (exists($allocated_octets{$octet1})) {
			    $tmp = $allocated_octets{$octet1};
			    if ($tmp ~~ /^\d+ /) {
				#
				# An overlapping class A network exists.
				#
				if ($tmp ~~ /^\S+ S /) {
				    #
				    # The class A network was a supernet.
				    #
				    $overlap = "";
				} else {
				    $overlap = $tmp;
				    $error = 1;
				}
			    }
			}
			unless ($overlap) {
			    $Net_Ranges{$subnet_key} = "";
			    $tmp = "$subnet_key $supernet$option $argument";
			    $allocated_octets{$subnet_key} = $tmp;
			    unless (exists($allocated_octets{$octet1})) {
				#
				# The first octet has not been allocated by a
				# previously-specified non-overlapping network.
				#
				$allocated_octets{$octet1} = $tmp;
			    }
			}
		    } elsif ($cidr_size <= 24) {
			$octet1 = $octets1_and_2 = $subnet_key;
			$octet1 ~~ s/[.].+//;
			$octets1_and_2 ~~ s/[.]\d+$//;
			if (exists($allocated_octets{$subnet_key})) {
			    $overlap = $allocated_octets{$subnet_key};
			    if (exists($Net_Ranges{"$subnet_key.X"})) {
				#
				# One or more overlapping sub-class-C
				# network(s) exist(s).
				#
				if ($supernet) {
				    $overlap = "";
				} else {
				    $error = 1;
				}
			    } elsif ($overlap !~ /\S+ $option /) {
				#
				# The duplicate class C network specification
				# is ambiguous because one is a -a option and
				# another is a -n option.
				#
				$error = 3;
			    }
			} elsif (exists($allocated_octets{$octets1_and_2})) {
			    $tmp = $allocated_octets{$octets1_and_2};
			    if ($tmp ~~ /^\d+[.]\d+ /) {
				#
				# An overlapping class B network exists.
				#
				if ($tmp ~~ /^\S+ S /) {
				    #
				    # The class B network was a supernet.
				    #
				    $overlap = "";
				} else {
				    $overlap = $tmp;
				    $error = 1;
				}
			    }
			} elsif (exists($allocated_octets{$octet1})) {
			    $tmp = $allocated_octets{$octet1};
			    if ($tmp ~~ /^\d+ /) {
				#
				# An overlapping class A network exists.
				#
				if ($tmp ~~ /^\S+ S /) {
				    #
				    # The class A network was a supernet.
				    #
				    $overlap = "";
				} else {
				    $overlap = $tmp;
				    $error = 1;
				}
			    }
			}
			unless ($overlap) {
			    $Net_Ranges{$subnet_key} = "";
			    $tmp = "$subnet_key $supernet$option $argument";
			    $allocated_octets{$subnet_key} = $tmp;
			    #
			    # Allocate octets 1 and 2 to this class-C network
			    # unless already allocated by a previously specified
			    # non-overlapping network.
			    #
			    unless (exists($allocated_octets{$octets1_and_2})) {
				$allocated_octets{$octets1_and_2} = $tmp;
			    }
			    unless (exists($allocated_octets{$octet1})) {
				$allocated_octets{$octet1} = $tmp;
			    }
			}
		    } else {
			#
			# Deal with sub-class-C networks (/25 to /32).
			# First, see if there is an overlap conflict with
			# some other class A, B, or C network.
			#
			$octet1 = $octets1_and_2 = $subnet_key;
			$octet1 ~~ s/[.].+//;
			$octets1_and_2 ~~ s/[.]\d+$//;
			if (exists($allocated_octets{$subnet_key})) {
			    if (exists($Net_Ranges{$subnet_key})) {
				#
				# An overlapping class-C network exists.
				#
				$tmp = $allocated_octets{$subnet_key};
				if ($tmp ~~ /^\S+ S /) {
				    #
				    # The class C network was a supernet.
				    #
				    $overlap = "";
				} else {
				    $overlap = $tmp;
				    $error = 1;
				}
			    }
			} elsif (exists($allocated_octets{$octets1_and_2})) {
			    $tmp = $allocated_octets{$octets1_and_2};
			    if ($tmp ~~ /^\d+[.]\d+ /) {
				#
				# An overlapping class B network exists.
				#
				if ($tmp ~~ /^\S+ S /) {
				    #
				    # The class B network was a supernet.
				    #
				    $overlap = "";
				} else {
				    $overlap = $tmp;
				    $error = 1;
				}
			    }
			} elsif (exists($allocated_octets{$octet1})) {
			    $tmp = $allocated_octets{$octet1};
			    if ($tmp ~~ /^\d+ /) {
				#
				# An overlapping class A network exists.
				#
				if ($tmp ~~ /^\S+ S /) {
				    #
				    # The class A network was a supernet.
				    #
				    $overlap = "";
				} else {
				    $overlap = $tmp;
				    $error = 1;
				}
			    }
			}
			unless ($overlap) {
			    #
			    # Now see if there are any sub-class-C overlaps
			    # within the parent class-C supernet.
			    # NOTE: Even though `h2n' will tolerate and
			    #       simply issue a warning when it detects
			    #       duplicate intra-class (A, B, and C only)
			    #       networks with identical -n or -a options,
			    #       no such indulgence will be made to see if
			    #       two such sub-class-C networks are exactly
			    #       duplicated because of the added variables
			    #       of the RFC-2317 zone name and the template
			    #       for PTR owner names.  Therefore, no IP
			    #       address overlap of any kind is permitted
			    #       for sub-class-C networks.
			    #
			    $class_c_key = $sub_class_c_key = $subnet_key;
			    unless (exists($Net_Ranges{"$class_c_key.X"})) {
				#
				# This is the first sub-class-C network in
				# the parent class-C supernet.
				#
				my $supernet = "";
				$Net_Ranges{"$class_c_key.X"} = $ip_range;
				$sub_class_c_key .= ".$ip_range";
				$Net_Ranges{$sub_class_c_key} = "";
				if (exists($allocated_octets{$class_c_key})) {
				    $tmp = $allocated_octets{$class_c_key};
				    if ($tmp ~~ /^\S+ S /) {
					#
					# The parent class-C network was
					# explicitly declared to be a supernet.
					# Preserve the flag in case there is a
					# subsequent sub-class-C network of the
					# same class-C parent.
					#
					$supernet = "S ";
				    }
				}
				$tmp = "$class_c_key $supernet$option"
				     . " $argument  $domain_arg "
				     . " $ptr_arg$other_args";
				$allocated_octets{$class_c_key} = $tmp;
				#
				# Allocate octets 1 and 2 to this sub-class-C
				# network unless already allocated by a
				# previously specified non-overlapping network.
				#
				unless (exists(
					$allocated_octets{$octets1_and_2})) {
				    $allocated_octets{$octets1_and_2} = $tmp;
				}
				unless (exists($allocated_octets{$octet1})) {
				    $allocated_octets{$octet1} = $tmp;
				}
				# Finally, register the sub-class-C hash key
				# so that a descriptive error message can be
				# generated in case a subsequent sub-class-C
				# network specification causes a conflict.
				#
				$allocated_octets{$sub_class_c_key} = $tmp;

			    } else {
				#
				# One or more sub-class-C networks already
				# exist in the parent class-C supernet.
				# The only valid situation at this point
				# is if we are appending a non-overlapping
				# IP address range to an existing list of
				# non-overlapping sub-class-C address ranges.
				#
				($first_ip,
				 $last_ip) = split(/-/, $ip_range, 2);
				$last_ip = $first_ip unless defined($last_ip);
				foreach $tmp (split(' ',
					      $Net_Ranges{"$class_c_key.X"})) {
				    ($tmp1, $tmp2) = split(/-/, $tmp, 2);
				    $tmp2 = $tmp1 unless defined($tmp2);
				    if (($first_ip >= $tmp1
					 && $first_ip <= $tmp2)
					|| ($tmp1 >= $first_ip
					    && $tmp1 <= $last_ip)) {
					#
					# An overlap exists.  Reconstruct
					# the sub-class-C index key into
					# the %allocated_octets hash so
					# that a descriptive error message
					# can be generated.
					#
					$overlap = $allocated_octets
						    {"$class_c_key.$tmp"};
					$error = 2;
					last;
				    }
				}
				unless ($overlap) {
				    #
				    # Append the non-overlapping range of
				    # addresses to the existing list and
				    # initialize the new hash key associated
				    # with this sub-class-C network.
				    #
				    $Net_Ranges{"$class_c_key.X"} .= " "
								   . $ip_range;
				    $sub_class_c_key .= ".$ip_range";
				    $Net_Ranges{$sub_class_c_key} = "";
				    #
				    # There is no need to register the parent
				    # class-C supernet in the %allocated_octets
				    # hash since this has already been done by
				    # the supernet's first sub-class-C network.
				    # However, we do want to register the
				    # current sub-class-C network so that
				    # any future conflict can be accompanied
				    # by a descriptive error message.
				    #
				    $allocated_octets{$sub_class_c_key} =
				        "$class_c_key $option $argument  "
					. "$domain_arg  $ptr_arg$other_args";
				}
			    }
			}
		    }
		    if ($overlap) {
			$overlap ~~ s/^\S+ (?:S )?//;
			unless ($error) {
			    if ($Verbose && !$already_warned) {
				print STDERR "Warning: overlapping $option ",
					     "option ($option $argument).\n",
					     "It redundantly includes one or ",
					     "more (sub)networks from a ",
					     "previous option:\n  $overlap\n",
					     "Check your -n/-a networks and ",
					     "subnetmasks/CIDRsizes for ",
					     "overlap.\n";
				$already_warned = 1;
				$overlap = "";
				$message_count++;
			    }
			} elsif ($error == 1) {
			    print STDERR "Improper $option option ",
					 "($option $argument).\n",
					 "It overlaps with a network of a ",
					 "different class from a previous ",
					 "option:\n  $overlap\nThey can't ",
					 "simultaneously specify a part of ",
					 "the same DNS address-to-name space.",
					 "\n";
			} elsif ($error == 2) {
			    print STDERR "Improper $option option ",
					 "($option $argument).\n",
					 "It overlaps with another ",
					 "sub-class-C network from a previous ",
					 "option:\n  $overlap\nTo prevent DNS ",
					 "naming ambiguities, sub-class-C ",
					 "overlaps are always disallowed.\n";
			} else {
			    print STDERR "Improper $option option ",
					 "($option $argument).\n",
					 "It conflicts with a previous option ",
					 "($overlap).\nA network ",
					 "specification cannot be shared ",
					 "between the -n and -a options.\n";
			}
			if ($error) {
			    GIVE_UP() unless defined wantarray;
			    $message_count++;
			    last;
			}
		    }
		    if ($subnet_key eq "127.0.0") {
			if ($option eq "-a") {
			    #
			    # Skip the automatic generation of the generic
			    # reverse-mapping db file for the loopback network.
			    #
			    $MakeLoopbackSOA = 0;
			} else {
			    #
			    # Skip the automatic declaration of the loopback
			    # network in the various configuration files
			    # generated by the GEN_BOOT() subroutine.
			    #
			    $MakeLoopbackZone = 0;
			}
		    }
		    next if $option eq "-a";

		    # Finish processing the -n option by creating the necessary
		    # data structures to allocate the "db.*" files to which the
		    # PTR records will get written.
		    #
		    if ($cidr_size <= 24) {
			if ($cidr_size == 8) {
			    #
			    # PTR records for a /8 network will get
			    # written to a single class-A zone file.
			    #
			    $ptr_template = "\$4.'.'.\$3.'.'.\$2";
			} elsif ($cidr_size <= 16) {
			    #
			    # PTR records for networks sizes /9 to /16 will get
			    # get written to the equivalent number of class-B
			    # zone files.
			    #
			    $ptr_template = "\$4.'.'.\$3";
			} else {
			    #
			    # PTR records for networks sizes /17 to /24 will get
			    # get written to the equivalent number of class-C
			    # zone files.
			    #
			    $ptr_template = "\$4";
			}
			$zone_file = $subnet_key;
			$zone_name = REVERSE($zone_file) . ".in-addr.arpa";
		    } else {
			#
			# Assemble the sub-class-C network information.
			#
			unless ($ptr_template) {
			    #
			    # No `ptr-owner=' argument was specified.
			    # Set the template to the appropriate default
			    # value based on the sub-class-C network's size.
			    #
			    if ($cidr_size == 32
				&& (!$rfc_2317_domain
				    || $rfc_2317_domain ~~ /^(?:\d+[.]){4}
							    in-addr.arpa$/ix)) {
				#
				# Accommodate the special case of the
				# PTR record being at the zone top
				# along with the SOA and NS records.
				#
				$ptr_template = "''";
				$ptr_arg = "[ptr-owner='']";
			    } else {
				$ptr_template = "\$4";
				$ptr_arg = "[ptr-owner=\$4]";
			    }
			}
			if ($rfc_2317_domain) {
			    $zone_name = $rfc_2317_domain;
			} else {
			    $zone_file = $sub_class_c_key;
			    $zone_name = REVERSE($zone_file) . ".in-addr.arpa";
			    $domain_arg = "[domain=$zone_name]";
			}
			$lc_zone_name = lc($zone_name);
			#
			# It is possible for multiple sub-class-C networks
			# belonging to different class-C supernets to specify
			# (explicitly or implicitly) the same "domain=" argument
			# in their respective `-n' options.
			# However, the default PTR template of `$4' is
			# insufficient in these cases because the last octet
			# that it represents is not unique across different
			# class-C supernets.
			# Choosing such a shared reverse-mapping zone requires
			# that the "ptr-owner=" argument be specified (either
			# explicitly or implicitly) so that the IP addresses of
			# each sub-class-C network map to unique PTR owner names
			# in the common zone file.
			#
			$ptr_map = "$class_c_key.xxx";
			$ptr_map ~~
			       s/(\d+)[.](\d+)[.](\d+)[.](\S+)/$ptr_template/ee;
			$ptr_map = lc($ptr_map);
			if (exists($sub_class_c{$lc_zone_name}{first_supernet})
			    && $sub_class_c{$lc_zone_name}{first_supernet}
			       ne $class_c_key
			    && exists($sub_class_c{$lc_zone_name}{$ptr_map})) {
			    $error = $sub_class_c{$lc_zone_name}{$ptr_map};
			    print STDERR "The following -n option is ",
					 "ambiguously specified:\n",
					 "  -n $argument  $domain_arg",
					 "  $ptr_arg$other_args\n",
					 "There is the possibility of ",
					 "overlapping PTR owner names with a ",
					 "prior -n option:\n  $error\n",
					 "Sub-class-C networks belonging to ",
					 "different class-C supernets must ",
					 "specify\nuniquely-mapping ",
					 "`ptr-owner=' arguments if they ",
					 "share a common domain name.\n";
			    GIVE_UP() unless defined wantarray;
			    $message_count++;
			    last;
			}
			$sub_class_c{$lc_zone_name}{$ptr_map} =
				  "$argument  $domain_arg  $ptr_arg$other_args";
			if ($rfc_2317_domain) {
			    if (lc($rfc_2317_domain) eq lc($Domain)) {
				#
				# The PTR records are to be written to the
				# same zone file as the forward-mapping
				# domain data (-d option).
				#
				$net_file = "DOMAIN";
				$Net_Ranges{$sub_class_c_key} =
				    "\*" . qualify($net_file) .
				    " "  . $ptr_template;
				unless (exists($sub_class_c{lc($Domain)}
							   {first_supernet})) {
				    $sub_class_c{lc($Domain)}
						{first_supernet} = $class_c_key;
				}
				next;
			    }
			    $zone_file = $rfc_2317_domain;
			    if ($rfc_2317_domain ~~ /[.]in-addr[.]arpa$/i) {
				$zone_file = REVERSE($rfc_2317_domain);
				$zone_file ~~ s/^arpa[.]in-addr[.]//i;
				$zone_file ~~ s/[.]($cidr_size)\/(.+)$/.$2\/$1/;
			    }
			    #
			    # Certain non-alphanumeric characters cause
			    # trouble when they appear in filenames but
			    # are nonetheless valid in a DNS domain name.
			    # Translate these nettlesome characters into
			    # a harmless "%" character after making sure
			    # to unescape any "$@()" characters.  Escaped
			    # whitespace will be converted to underscore
			    # characters and then any remaining escapes
			    # will be eliminated.
			    #
			    for ($zone_file) {
				s/\\([\$@\(\)])/$1/g;
				s/[\/<|>&\[\(\)\$\?;'`]/%/g;
				s/\\\s/_/g;
				s/\\//g;
			    }
			}
		    }
		    $net_file = "DB.$zone_file";
		    #
		    # Prepend our package name to the value that is stored
		    # in the "%Net_Ranges" hash.  This hash value is used
		    # as a globally-scoped file descriptor typeglob for
		    # printing RRs to the DB files and as a key into
		    # the "%DB_Filehandle" hash.
		    #
		    $subnet_key = $sub_class_c_key if $cidr_size >= 25;
		    $Net_Ranges{$subnet_key} = "\*" . qualify($net_file) .
					       " "  . $ptr_template;
		    next if ($cidr_size >= 25
			     && exists($sub_class_c{$lc_zone_name}
						   {first_supernet}));

		    # Make sure the SOA record gets created as well as
		    # adding the necessary entries to the boot/conf file(s).
		    #
		    if ($alt_spcl_file) {
			#
			# Unlike the default case where the presence of
			# a "spcl.NET" file is optional, files that are
			# explicitly configured via the "spcl=" argument
			# of the -n option are expected to exist.
			# However, since the -W option for specifying the
			# working directory of `h2n' may not yet be known,
			# we can't start looking now.  These "spcl" files
			# will be stored into "@alt_spcl_files" and be
			# checked once all options have been processed.
			#
			$spcl_file = $alt_spcl_file;
			push(@alt_spcl_files,
					"-n $argument ... spcl=$alt_spcl_file");
		    } else {
			$spcl_file = "spcl.$zone_file";
		    }
		    $zone_file = ($alt_db_file) ?? $alt_db_file
						!! "db.$zone_file";
		    push(@Make_SOA, "$zone_file $net_file");
		    push(@Boot_Msgs, "$zone_name $zone_file");
		    $Net_Zones{$subnet_key} = "$zone_name $spcl_file";
		    if ($cidr_size >= 25) {
			$sub_class_c{$lc_zone_name}
				    {first_supernet} = $class_c_key;
		    }
		    $last_n_or_d .= " $zone_file";

		}   # end of "foreach $subnet" loop
	    }	    # end of "while (@option_args)" loop

	} elsif ($option eq "-B") {
	    $Boot_Dir = shift(@option_args);
	    1 while $Boot_Dir ~~ s/\/\//\//g;	# remove redundant "/" chars.
	    $Boot_Dir ~~ s/(.)\/$/$1/;		# remove trailing "/" char.
	    $Boot_Dir = $cwd if $Boot_Dir eq ".";
	    $error = 0;
	    unless ($Boot_Dir ~~ /^\//) {
		print STDERR "Must use an absolute pathname ",
			     "for the -B option.\n";
		$error = 1;
	    } elsif (!-d $Boot_Dir || !-r _ || !-w _) {
		print STDERR "Improper -B option ($Boot_Dir).\n",
			     "The specified directory is non-existent, ",
			     "invalid, or has no read/write access.\n";
		$error = 1;
	    }
	    if ($error) {
		GIVE_UP() unless defined wantarray;
		$message_count++;
	    }

	} elsif ($option eq "-b") {
	    $Bootfile = shift(@option_args);
	    1 while $Bootfile ~~ s/\/\//\//g;
	    $Bootfile ~~ s/^[.]\///;
	    if ($Bootfile ~~ /\// && $Bootfile ne "/dev/null") {
		print STDERR "Improper -b option; no pathname ",
			     "is allowed in the boot file specification.\n",
			     "Use the -B option to specify an alternate ",
			     "directory for boot/conf files.\n";
		GIVE_UP() unless defined wantarray;
		$message_count++;
	    }

	} elsif ($option eq "-C") {
	    $Commentfile = shift(@option_args);
	    unless (-f $Commentfile && -r _) {
		print STDERR "Improper -C option ($Commentfile).\n",
			     "The specified file is non-existent, ",
			     "invalid, or has no read access.\n";
		GIVE_UP() unless defined wantarray;
		$message_count++;
	    }

	} elsif ($option eq "-c") {
	    #
	    # NOTE: The historical behavior of `-c' option processing
	    #       was to append the `-d' domain to all single-label
	    #       names.  This prevented the `-c' option from working
	    #       with Top-Level Domains (TLDs).  To maintain backwards
	    #       compatibility, TLDs must be distinguished by being
	    #       absolute domain names, i.e., being terminated by a
	    #       "." character.
	    #
	    @insertion_args = ();
	    $error = 0;
	    while (@option_args) {
		$current_arg = shift(@option_args);
		if ($current_arg ~~ /^mode=/i) {
		    print STDERR "Improper -c option; a domain name must ",
				 "precede the `$current_arg' argument.\n";
		    GIVE_UP() unless defined wantarray;
		    $message_count++;
		    $error = 1;
		    last;
		}
		if (length($current_arg) == 0
		    || CHECK_NAME($current_arg, 'SOA')) {
		    print STDERR "Improper -c option; the domain name ",
				 "`$current_arg' is invalid.\n";
		    GIVE_UP() unless defined wantarray;
		    $message_count++;
		    $error = 1;
		    last;
		}
		unless ($current_arg ~~ /[.]/) {
		    unless ($Domain) {
			print STDERR "Improper -c option; the single-label ",
				     "non-absolute domain name of ",
				     "`$current_arg'\n",
				     "requires that the -d option be ",
				     "previously specified so that\n",
				     "the default domain name can be ",
				     "appended.\n";
			GIVE_UP() unless defined wantarray;
			$message_count++;
			$error = 1;
			last;
		    } else {
			#
			# Append the -d Domain to any domain argument
			# that is a single-label non-absolute name.
			#
			$domain_arg = "$current_arg.$Domain";
		    }
		} else {
		    #
		    # The domain argument is a multi-label domain name
		    # or a single-label absolute TLD (Top-Level Domain).
		    #
		    ($domain_arg = $current_arg) ~~ s/[.]$//;
		}
		($pattern = lc($domain_arg)) ~~ s/[.]/\\./g;
		if (exists($c_Opt_Pat_Rel{$pattern})) {
		    print STDERR "Improper -c option; the domain ",
				 "`$current_arg' has\n",
				 "already been specified in a prior -c option.",
				 "\n";
		    GIVE_UP() unless defined wantarray;
		    $message_count++;
		    $error = 1;
		    last;
		}
		$c_Opt_Pat_Rel{$pattern} = $domain_arg;
		push(@c_Opt_Patterns, $pattern);
		$c_Opt_Spec{$pattern}{MODE} = "";	# a `mode=' argument								# may update this later

		# See if there's an optional `mode=' argument.
		#
		if (@option_args && $option_args[0] ~~ /^mode=/i) {
		    $token = shift(@option_args);
		    ($argument = uc($token)) ~~ s/^MODE=//;
		    $argument ~~ s/[,]//g;
		    $error = 0;
		    unless ($argument ~~ /^[ADHIQS]+$/) {
			print STDERR "Improper `$token' argument in -c ",
				     "option.\n",
				     "Components of a valid `mode=' value ",
				     "are: A, D, H, I, Q, and S.\n";
			$error = 1;
		    } elsif ($argument ~~ /(?:H.*S|S.*H)/) {
			print STDERR "Improper `$token' argument in -c ",
				     "option.\n",
				     "'mode=' components of \"H\" and \"S\" ",
				     "are mutually exclusive.\n";
			$error = 1;
		    } elsif ($argument ~~ /^(?:[AHIS]*Q|Q[AHIS]*)$/) {
			print STDERR "Improper `$token' argument in -c ",
				     "option.\n",
				     "'mode=' component of \"Q\" requires ",
				     "that \"D\" also be specified.\n";
			$error = 1;
		    } elsif ($argument ~~ /I/ && !$Domain) {
			print STDERR "Improper `$token' argument in -c ",
				     "option.\n",
				     "'mode=' component of \"I\" requires ",
				     "that the -d option be previously ",
				     "specified.\n";
			$error = 1;
		    } elsif ($argument ~~ /I/ &&
			     $c_Opt_Pat_Rel{$pattern} !~ /$Domain_Pattern$/io) {
			print STDERR "Improper `-c $c_Opt_Pat_Rel{$pattern}' ",
				     "option.\n",
				     "The `mode=' component of \"I\" requires ",
				     "the -c domain to be\n",
				     "an intra-zone subdomain of the -d ",
				     "option ($Domain).\n";
			$error = 1;
		    } elsif ($argument ~~ /(?:I.*[HS]|[HS].*I)/) {
			($tmp2 = $argument) ~~ s/[ADIQ]//g;
			if ($Verbose) {
			    print STDERR "Improper `$token' argument in -c ",
					 "option.\n",
					 "Ignoring 'mode=' component of ",
					 "\"$tmp2\" (for external domains ",
					 "only)\nwhen \"I\" (intra-zone ",
					 "subdomain) is also specified.\n";
			    $message_count++;
			}
		    }
		    if ($error) {
			GIVE_UP() unless defined wantarray;
			$message_count++;
			last;
		    }
		    # Update the mode-tracking hash with the actual flag(s).
		    #
		    $c_Opt_Spec{$pattern}{MODE} = $argument;
		    if ($argument ~~ /[HS]/) {
			#
			# Add the enabled -[hide|show]-dangling-cnames option
			# to a temporary buffer that will be added to the
			# option/argument stream after finishing the current
			# -c option.
			#
			$tmp2  = ($argument ~~ /H/) ?? "-hide" !! "-show";
			$tmp2 .= "-dangling-cnames";
			push(@insertion_args, $tmp2, $c_Opt_Pat_Rel{$pattern});
		    }
		}
	    }
	    if (@insertion_args && !$error) {
		@args = (@insertion_args, @args);
	    }

	} elsif ($option eq "+C") {
	    $Conf_Prefile = shift(@option_args);
	    1 while $Conf_Prefile ~~ s/\/\//\//g;
	    $Conf_Prefile ~~ s/^[.]\///;
	    if ($Conf_Prefile ~~ /\//) {
		print STDERR "Improper +C option; no pathname is allowed ",
			     "in the `conf' prepend file spec.\n",
			     "Use the -B option to specify an alternate ",
			     "directory for boot/conf files.\n";
		GIVE_UP() unless defined wantarray;
		$message_count++;
	    }

	} elsif ($option eq "+c") {
	    $argument = shift(@option_args);
	    unless ($argument ~~ /^mode=/i) {
		$Conffile = $argument;
		1 while $Conffile ~~ s/\/\//\//g;
		$Conffile ~~ s/^[.]\///;
		if ($Conffile ~~ /\// && $Conffile ne "/dev/null") {
		    print STDERR "Improper +c option; no pathname is allowed ",
				 "in the conf file specification.\n",
				 "Use the -B option to specify an alternate ",
				 "directory for boot/conf files.\n";
		    GIVE_UP() unless defined wantarray;
		    $message_count++;
		    next;
		} else {
		    $argument = "";
		}
	    } else {
		$token = $argument;
		($argument = uc($token)) ~~ s/^MODE=//;
	    }
	    #
	    # If necessary, see if there's an optional `mode=' argument.
	    #
	    unless ($argument) {
		if (@option_args && $option_args[0] ~~ /^mode=/i) {
		    $token = shift(@option_args);
		    ($argument = uc($token)) ~~ s/^MODE=//;
		}
	    }
	    if ($argument) {
		unless ($argument ~~ /^[MS]$/) {
		    print STDERR "Improper `$token' argument in +c option.\n",
				 "The component of a valid `mode=' value is ",
				 "either `M' or `S'.\n";
		    GIVE_UP() unless defined wantarray;
		    $message_count++;
		} else {
		    $New_Fmt_Conffile = ($argument eq "M") ?? 1 !! 0;
		}
	    }

	} elsif ($option eq "-D") {
	    $Delegate = 1;
	    if (@option_args) {
		$Del_File = shift(@option_args);
	    }

	} elsif ($option eq "-d") {
	    $argument = shift(@option_args);
	    if ($argument ~~ /^(?:db|spcl|mode)=/i) {
		print STDERR "Improper -d option; a domain name must ",
			     "precede any `db=|spcl=|mode=' arguments.\n";
		GIVE_UP() unless defined wantarray;
		$message_count++;
		next;
	    }
	    if ($Domain) {
		if ($Verbose) {
		    print STDERR "Extra -d option ($argument) ignored, ",
				 "only one instance allowed.\n";
		    $message_count++;
		}
		@option_args = ();
		next;
	    }
	    ($Domain = $argument) ~~ s/[.]$//;
	    if (length($Domain) == 0 || CHECK_NAME($Domain, 'SOA')) {
		print STDERR "Improper -d option; the domain name ",
			     "`$argument' is invalid.\n";
		GIVE_UP() unless defined wantarray;
		$message_count++;
		next;
	    }
	    ($Domain_Pattern = ".$Domain") ~~ s/[.]/\\./g;# for stripping domain
	    ($Domainfile = $Domain) ~~ s/[.].*//;
	    $Domainfile  = "db.$Domainfile";
	    #
	    # NOTE: Defer the default initialization of "$Special_File" until
	    #       the complete list of submitted options has been processed.
	    #       Once the status of the -W option is known, the validation
	    #       of a `spcl=' argument can be made.
	    #
	    # Process any optional arguments that may be present.
	    #
	    while (@option_args) {
		$argument = shift(@option_args);
		unless ($argument ~~ /^(?:db|mode|spcl)=/i) {
		    print STDERR "Improper -d option; unknown argument ",
				 "($argument).\n";
		    GIVE_UP() unless defined wantarray;
		    $message_count++;
		    last;
		} elsif ($argument ~~ /^db=/i) {
		    ($Domainfile = $argument) ~~ s/^db=//i;
		    1 while $Domainfile ~~ s/\/\//\//g;
		    $Domainfile ~~ s/^[.]\///;
		    if ($Domainfile ~~ /\//) {
			print STDERR "Improper `$argument' argument in -d ",
				     "option.\n",
				     "No pathname is allowed in the alternate ",
				     "DB file specification.\n",
				     "Use the -W option to specify an ",
				     "alternate directory for DB files.\n";
			GIVE_UP() unless defined wantarray;
			$message_count++;
			last;
		    }
		} elsif ($argument ~~ /^spcl=/i) {
		    ($Special_File = $argument) ~~ s/^spcl=//i;
		    1 while $Special_File ~~ s/\/\//\//g;
		    $Special_File ~~ s/^[.]\///;
		    if ($Special_File ~~ /\//) {
			print STDERR "Improper `$argument' argument in -d ",
				     "option.\n",
				     "No pathname is allowed in the `spcl' ",
				     "\$INCLUDE file specification.\n",
				     "Use the -W option to specify an ",
				     "alternate directory for `spcl' files.\n";
			GIVE_UP() unless defined wantarray;
			$message_count++;
			last;
		    } else {
			push(@alt_spcl_files,
			     "-d $Domain ... spcl=$Special_File");
		    }
		} else {
		    if ($argument ~~ /^mode=D$/i) {
			$UseDefaultDomain = 1;
		    } elsif ($argument ~~ /^mode=Q$/i) {
			$ReportNonMatchingDomains = 0;
		    } elsif ($argument ~~ /^mode=(?:DQ|QD)$/i) {
			print STDERR "Improper `$argument' argument in -d ",
				     "option.\n",
				     "The 'mode=' components \"D\" and \"Q\" ",
				     "are mutually exclusive.\n";
			GIVE_UP() unless defined wantarray;
			$message_count++;
			last;
		    } else {
			print STDERR "Improper `$argument' argument in -d ",
				     "option.\n",
				     "The component of a valid `mode=' value ",
				     "must be `D' or `Q'.\n";
			GIVE_UP() unless defined wantarray;
			$message_count++;
			last;
		    }
		}
	    }

	    # Add the forward-mapping entry to the boot/conf file.
	    #
	    $last_n_or_d   = "-d $Domainfile";
	    push(@Make_SOA,  "$Domainfile DOMAIN");
	    push(@Boot_Msgs, "$Domain $Domainfile");

	} elsif ($option eq "-e") {
	    #
	    # NOTE: The historical behavior of `-e' option processing
	    #       was to append the `-d' domain to all single-label
	    #       names.  This prevented the `-e' option from working
	    #       with Top-Level Domains (TLDs).  To maintain backwards
	    #       compatibility, TLDs must be distinguished by being
	    #       absolute domain names, i.e., being terminated by a
	    #       "." character.
	    #
	    while (@option_args) {
		$current_arg = shift(@option_args);
		if (length($current_arg) == 0
		    || CHECK_NAME($current_arg, 'SOA')) {
		    print STDERR "Improper -e option; the domain name ",
				 "`$current_arg' is invalid.\n";
		    GIVE_UP() unless defined wantarray;
		    $message_count++;
		    last;
		}
		unless ($current_arg ~~ /[.]/) {
		    unless ($Domain) {
			print STDERR "Improper -e option; the single-label ",
				     "non-absolute domain name of ",
				     "`$current_arg'\n",
				     "requires that the -d option be ",
				     "previously specified so that\n",
				     "the default domain name can be ",
				     "appended.\n";
			GIVE_UP() unless defined wantarray;
			$message_count++;
			last;
		    } else {
			#
			# Append the -d Domain to any domain argument
			# that is a single-label non-absolute name.
			#
			$domain_arg = lc("$current_arg.$Domain");
		    }
		} else {
		    #
		    # The domain argument is a multi-label domain name
		    # or a single-label absolute TLD (Top-Level Domain).
		    #
		    ($domain_arg = lc($current_arg)) ~~ s/[.]$//;
		}
		if (exists($e_opt_domain{$domain_arg})) {
		    print STDERR "Improper -e option; the domain ",
				 "`$current_arg' has\n",
				 "already been specified in a prior -e option.",
				 "\n";
		    GIVE_UP() unless defined wantarray;
		    $message_count++;
		    last;
		}
		($pattern = $domain_arg) ~~ s/[.]/\\./g;
		push(@e_Opt_Patterns, $pattern);
		$e_opt_domain{$domain_arg} = 1;
	    }

	} elsif ($option eq "-f") {
	    $file = shift(@option_args);
	    unless (-e $file && -f _ && -r _) {
		print STDERR "Bad options file specification; `$file' ";
		if (! -e $file) {
		    print STDERR "does not exist.\n";
		} elsif (! -f $file) {
		    print STDERR "is not a plain file.\n";
		} else {
		    print STDERR "is not readable.\n";
		}
		GIVE_UP() unless defined wantarray;
		$message_count++;
		next;
	    }
	    $tmp1 = join(":", (stat($file))[0..1]);
	    if ($tmp1 eq $RCfile) {
		print STDERR "Warning: -f option ignored; `$file' has been ",
			     "already\n",
			     "         processed as an $Program configuration ",
			     "file.\n";
		$message_count++;
		next;
	    } elsif (exists($f_opt_file{$tmp1})) {
		print STDERR "Warning: -f option ignored; `$file' has been ",
			     "already\n",
			     "         processed as a previous -f option ",
			     "file.\n";
		$message_count++;
		next;
	    }
	    $f_opt_file{$tmp1} = $file;		# Keep track of each -f file.
	    unless (open(*OPT, '<', $file)) {
		print STDERR "Unable to open options file `$file': $!\n";
		GIVE_UP() unless defined wantarray;
		$message_count++;
		next;
	    }
	    # Read through each line of the options file and split it into a
	    # stream of individual option/argument tokens via the following
	    # shell-like rules:
	    #
	    #   1. Quoting characters are the escape (\), the literal or
	    #      single quote ('), and the grouping or double quote (").
	    #   2. Tokens are delimited by unquoted whitespace (space, tab,
	    #      and newline).  Multi-line tokens are not allowed, however.
	    #      A quoted newline generates an "unexpected end of input"
	    #      error.
	    #   3. Tokens that begin with an unquoted "#" or ";" character
	    #      signify the start of a comment which then extends to
	    #      the rest of the line.
	    #   4. A pair of literal (single) quotes removes the special
	    #      meaning of all enclosed characters, i.e., nothing can be
	    #      escaped since "\" becomes a literal backslash character.
	    #      Use \' or "'" outside of single quotes to refer to the
	    #      literal ' character.
	    #   5. A pair of grouping (double) quotes removes the special
	    #      meaning of all enclosed characters except "\" and the
	    #      double quote itself.  This means that the backslash and
	    #      the double quote character can be rendered into their
	    #      literal meaning by preceding them with an escape.
	    #
	    @insertion_args = ();
	    $line_num = $skip_next_token = 0;
	    $error = "";
	    while (<OPT>) {
		$line_num++;
		chop;
		s/\s+$//;
		$original_line = $_;
		s/^\s+//;
		next if /^$/ || /^[#;]/;
		$comment = 0;
		unless (/[\\"']/) {
		    foreach $token (split(' ')) {
			if ($token ~~ /^[#;]/) {
			    $comment = 1;
			    last;
			}
			push(@insertion_args, $token);
		    }
		    next if $comment;
		} else {
		    #
		    # Assemble a token character-by-character until unquoted
		    # whitespace or the end of the line is reached.
		    #
		    $token = "";
		    $open_quote = 0;
		    while (length($_)) {
			($char, $_) = split(//, $_, 2);
			if ($open_quote == 1) {
			    if ($char eq "'") {
				$open_quote = 0;
				next;
			    }
			} elsif ($char eq "\\") {
			    unless (length($_)) {
				$error = "unexpected end of input\n> "
					 . "$original_line";
				last;
			    }
			    ($char, $_) = split(//, $_, 2);
			} elsif ($open_quote == 2) {
			    if ($char eq '"') {
				$open_quote = 0;
				next;
			    }
			} elsif ($char eq "'") {
			    $open_quote = 1;
			    next;
			} elsif ($char eq '"') {
			    $open_quote = 2;
			    next;
			} elsif ($char ~~ /\s/) {
			    if ($token ~~ /[#;]/) {
				$comment = 1;
				last;
			    } else {
				push(@insertion_args, $token);
			    }
			    $token = "";
			    s/^\s+//;
			    next;
			}
			$token .= $char;
		    }
		    if ($open_quote) {
			$error = "unbalanced quotes\n> $original_line";
		    } elsif (!$comment && !$error) {
			push(@insertion_args, $token);
		    }
		}
		last if $error;
	    }
	    close(*OPT);
	    if ($error) {
		print STDERR "Error in option file `$file' at line $line_num; ",
			     "$error\n";
		GIVE_UP() unless defined wantarray;
		$message_count++;
	    } else {
		#
		# Preserve the order in which the arguments were presented
		# to this program by inserting the parsed tokens of the
		# just-read options file ahead of those from the original
		# argument list that still remain to be processed.
		# The next argument to be processed will be the first one
		# from the just-read file.
		#
		@args = (@insertion_args, @args);
	    }

	} elsif ($option eq "-H") {
	    $Hostfile = shift(@option_args);
	    if ($Hostfile ne "-") {		# file "-" stands for STDIN
		unless (-f $Hostfile && -r _) {
		    print STDERR "Improper -H option ($Hostfile).\n",
				 "The specified file is non-existent, ",
				 "invalid, or has no read access.\n";
		    GIVE_UP() unless defined wantarray;
		    $message_count++;
		}
	    }

	} elsif ($option eq "-h") {
	    $Host = shift(@option_args);

	} elsif ($option eq "-I") {
	    #
	    # Maintain backward-compatibility in case there is no argument.
	    #
	    $Check_Level = "fail";
	    $RFC_952 = 0;
	    $RFC_1123 = 1;
	    $Audit = 1;
	    $DefAction = "Skipping";
	    while (@option_args) {
		$argument = shift(@option_args);
		if ($argument ~~ /^(?:no|false|off|none|disable|ignore)$/i) {
		    $Check_Level = "ignore";
		    $RFC_952 = 0;
		    $RFC_1123 = 0;
		    $Audit = 0;
		    $DefAction = "Warning";
		} elsif ($argument ~~ /^warn$/i) {
		    $Check_Level = "warn";
		    $RFC_952 = 0;
		    $RFC_1123 = 1;
		    $Audit = 0;
		    $DefAction = "Warning";
		} elsif ($argument ~~ /^audit\-only$/i) {
		    $Check_Level = "audit-only";
		    $RFC_952 = 0;
		    $RFC_1123 = 0;
		    $Audit = 1;
		    $DefAction = "Warning";
		} elsif ($argument ~~ /^audit$/i) {
		    $Check_Level = "audit";
		    $RFC_952 = 0;
		    $RFC_1123 = 1;
		    $Audit = 1;
		    $DefAction = "Warning";
		} elsif ($argument ~~ /^warn\-strict$/i) {
		    $Check_Level = "warn-strict";
		    $RFC_952 = 1;
		    $RFC_1123 = 1;
		    $Audit = 1;
		    $DefAction = "Warning";
		} elsif ($argument ~~ /^(?:yes|true|on|check|enable|fail)$/i) {
		    $Check_Level = "fail";
		    $RFC_952 = 0;
		    $RFC_1123 = 1;
		    $Audit = 1;
		    $DefAction = "Skipping";
		} elsif ($argument ~~ /^strict$/i) {
		    $Check_Level = "strict";
		    $RFC_952 = 1;
		    $RFC_1123 = 1;
		    $Audit = 1;
		    $DefAction = "Skipping";
		} elsif ($argument ~~ /^rfc-?2782$/i) {
		    $RFC_2782 = 1;
		} else {
		    if ($Verbose) {
			print STDERR "Unknown `-I' argument (`$argument'); ",
				     "name checking remains `$Check_Level'.\n";
			$message_count++;
		    }
		}
	    }

	} elsif ($option eq "-i") {
	    $argument = shift(@option_args);
	    $error = 0;
	    if ($UseDateInSerial) {
		print STDERR "Improper -i option; it is incompatible ",
			     "with the already-specified -y option.\n";
		$error = 1;
	    } elsif ($argument !~ /^\d+$/ || $argument > 4294967295) {
		print STDERR "Improper -i option; the SOA serial number ",
			     "must be a non-negative\n",
			     "integer between zero and 4294967295.  ",
			     "See RFC-1982 for details.\n";
		$error = 1;
	    }
	    if ($error) {
		GIVE_UP() unless defined wantarray;
		$message_count++;
	    } else {
		$New_Serial = $argument;
		if ($New_Serial == 0) {
		    print STDERR "Warning: Setting the SOA serial number to ",
				 "zero may cause unpredictable results\n",
				 "         with slave name servers.  ",
				 "See RFC-1982, Section 7 for details.\n";
		    $message_count++;
		}
	    }

	} elsif ($option eq "-L") {
	    $argument = shift(@option_args);
	    if ($argument !~ /^\d+$/ && $Verbose) {
		print STDERR "Expected numerical argument for -L option; ",
			     "ignored.\n";
		$message_count++;
	    } elsif ($argument < 10) {
		if ($Verbose) {
		    print STDERR "Using minimum value of 10 for -L option.\n";
		    $message_count++;
		}
		$Open_File_Limit = 10;
	    } else {
		$Open_File_Limit = $argument;
	    }

	} elsif ($option eq "+L") {
	    $CustomLogging = 1;
	    $argument = join(" ", @option_args);
	    if ($argument) {
		$argument ~~ s/ +$//;
		$argument .= ";" unless $argument ~~ /;$/;
		push(@Conf_Logging, $argument);
		@option_args = ();
	    }

	} elsif ($option eq "-M") {
	    #
	    # Maintain backward-compatibility in case there is no argument.
	    #
	    $Do_MX = "";
	    while (@option_args) {
		$argument = shift(@option_args);
		if ($argument ~~ /^no[-_]?mx$/i) {
		    $Do_MX = "[no mx]";
		} elsif ($argument ~~ /^smtp$/i) {
		    $Do_MX = "[smtp]";
		} elsif ($argument ~~ /^no[-_]?smtp$/i) {
		    $Do_MX = "[no smtp]";
		} else {
		    if ($Verbose) {
			print STDERR "Unknown `-M' argument (`$argument'); ",
				     "no MX records will be generated.\n";
			$message_count++;
		    }
		}
	    }

	} elsif ($option eq "-m") {
	    while (@option_args) {
		$argument = shift(@option_args);
		($preference, $domain_arg) = split(/:/, $argument, 2);
		$error = 0;
		unless ($preference && $preference ~~ /^\d+$/
			&& $preference <= 65535) {
		    print STDERR "Improper -m option; invalid MX preference ",
				 "value ($preference).\n";
		    $error = 1;
		} elsif (!$domain_arg) {
		    print STDERR "Improper -m option; missing MX hostname.\n";
		    $error = 1;
		} elsif ($domain_arg ~~ /^\d+[.]\d+[.]\d+[.]\d+$/) {
		    print STDERR "Uh, the -m option requires a domain name, ",
				 "not an IP address.\n";
		    $error = 1;
		}
		if ($error) {
		    GIVE_UP() unless defined wantarray;
		    $message_count++;
		    last;
		} else {
		    push(@MX, "$preference $domain_arg");
		}
	    }

	} elsif ($option eq "+m") {
	    $argument = join("", @option_args);
	    $argument ~~ s/^mode=//i;
	    $argument ~~ s/[,]//g;
	    $argument = "D" unless $argument;
	    @option_args = ();
	    unless ($argument ~~ /^(?:D|C|P|CP|PC)$/i) {
		print STDERR "Improper `$argument' argument in +m option.\n",
			     "Valid argument must be one of: D, C, P, or CP.\n";
		GIVE_UP() unless defined wantarray;
		$message_count++;
	    } else {
		$argument = uc($argument);
		if ($Multi_Homed_Mode && ($Multi_Homed_Mode != $argument)
		    && $Verbose) {
		    print STDERR "Hmm, using `+m $argument' to override ",
				 "previous +m option.\n";
		    $message_count++;
		}
		$Multi_Homed_Mode = $argument;
	    }

	} elsif ($option eq "-N") {
	    $argument = shift(@option_args);
	    if ($argument ~~ /^\//) {
		($cidr_size = $argument) ~~ s/^\///;
		$Defsubnetmask = undef;
	    } else {
		$cidr_size = undef;
		$Defsubnetmask = $argument;
	    }
	    $error = CHECK_NET(undef, \$cidr_size, \$Defsubnetmask);
	    if ($error) {
		print STDERR "Improper -N option ($argument):\n$error";
		GIVE_UP() unless defined wantarray;
		$message_count++;
	    } elsif ($cidr_size < 8) {
		print STDERR "Improper -N option ($argument).\n",
			     "Only network sizes /8 to /32 are supported.\n";
		GIVE_UP() unless defined wantarray;
		$message_count++;
	    }

	} elsif ($option eq "-O") {
	    $argument = join(" ", @option_args);
	    push(@Boot_Opts, $argument);
	    @option_args = ();

	} elsif ($option eq "-o") {
	    $argument = shift(@option_args);
	    unless ("$argument:" ~~ /^(?:(?:\d+|(?:\d+[wdhms])+)?:){1,5}$/i ||
		    $argument ~~ /^:{3,4}$/ || $argument !~ /^(?:[+-].*)?$/) {
		print STDERR "Improper -o option `$argument'.\n";
		GIVE_UP() unless defined wantarray;
		$message_count++;
		next;
	    }
	    # As of version 2.40 of `h2n', RFC-2308 status is assumed
	    # unless one of the following two conditions is true:
	    #
	    #   1. We are able to determine that a BIND version earlier
	    #      than 8.2 is running on the master name server.
	    #
	    #   2. The BIND version is unknown *and* exactly four arguments
	    #      (any of which can be null) are specified in the -o option
	    #      *and* no +t option is specified *and* no $TTL directive is
	    #      discovered in an existing DB file.
	    #
	    # Here are some examples that illustrate the various contexts:
	    #
	    #   -o :::          Special case of explicitly specifying `h2n'
	    #                   default SOA values and toggling the default
	    #                   RFC-2308 status to false.
	    #
	    #   -o :30m::       Sets SOA Retry field for all DB files and
	    #                   toggles the default RFC-2308 status to false.
	    #
	    #   -o :::8h        Sets non-RFC-2308 TTL interval in the
	    #                   SOA Minimum field for all DB files and toggles
	    #			the default RFC-2308 status to false.
	    #
	    #   -o :30m::8h     Combines the previous two examples while
	    #                   toggling the default RFC-2308 status to false.
	    #
	    #   -o 3h:1h:1w:1d  Explicitly specifies all four default SOA values
	    #                   and sets the default RFC-2308 status to false.
	    #
	    #   -o ::::         Special case of explicitly specifying `h2n'
	    #                   default SOA values and leaving the default
	    #                   RFC-2308 status to true.
	    #
	    #   -o :30m         Sets SOA Retry field for all DB files but leaves
	    #                   the default RFC-2308 status to true since there
	    #                   are not exactly four arguments specified.
	    #
	    #   -o ::::8h       Sets RFC-2308 $TTL directive for all DB files.
	    #                   SOA Minimum fields either retain existing values
	    #                   or get the default negative caching interval.
	    #
	    #   -o :::30m:      Sets RFC-2308 negative caching interval in the
	    #                   SOA Minimum field for all DB files.
	    #                   $TTL directives either retain existing values
	    #                   or are created with the default TTL value.
	    #
	    #   -o :::30m:8h    Sets SOA Minimum field and RFC-2308 $TTL
	    #                   directive for all DB files.
	    #
	    # The default $TTL value and negative caching interval can
	    # also be set with the +t option.  However, doing so will
	    # set the "$RFC_2308" flag to a "hard" value of 2 which only
	    # the FIXUP() subroutine can reverse if it detects a BIND
	    # version earlier than 8.2.  The -o option can toggle the
	    # "$RFC_2308" flag between 0 (non-RFC-2308 status) and 1
	    # ("soft" RFC-2308 status) as long as +t is not specified.
	    #
	    $tmp_ttl = $tmp_master_ttl = "";
	    if ($Refresh || $Retry || $Expire || $Ttl || $Master_Ttl) {
		if ($Verbose) {
		    print STDERR "Hmm, using `-o $argument' to override ",
				 "previous -o/+t option.\n";
		    $message_count++;
		}
		if ($RFC_2308 && ($Ttl || $Master_Ttl)) {
		    if ($RFC_2308 != 2 && $argument ~~ /^(?:[^:]*:){3}[^:]*$/) {
			if ($Verbose) {
			    print STDERR "(Ignoring previous \$TTL/Negative ",
					 "cache value(s).)\n";
			    $message_count++;
			}
			$Ttl = $Master_Ttl = "";
		    } elsif ($argument !~ /^(?:[^:]*:){3,4}[^:]*$/) {
			if ($Verbose) {
			    print STDERR "(Retaining previous \$TTL/Negative ",
					 "cache value(s), however.)\n";
			    $message_count++;
			}
			$tmp_ttl = $Ttl if $Ttl;
			$tmp_master_ttl = $Master_Ttl if $Master_Ttl;
		    }
		}
	    }
	    if ($RFC_2308 != 2) {
		$RFC_2308 = ($argument ~~ /^(?:[^:]*:){3}[^:]*$/) ?? 0 !! 1;
	    }
	    ($Refresh, $Retry, $Expire, $Ttl,
					$Master_Ttl) = split(/:/, $argument);
	    $Ttl = $tmp_ttl if $tmp_ttl;
	    $Master_Ttl = $tmp_master_ttl if $tmp_master_ttl;
	    if ($Verbose) {
		$message_count++ if CHECK_SOA_TIMERS();
	    }

	} elsif ($option eq "+O") {
	    $argument = join(" ", @option_args);
	    $CustomOptions = 1;
	    if ($argument) {
		$argument ~~ s/ +$//;
		$argument .= ";" unless $argument ~~ /[;{]$/;
		push(@Conf_Opts, $argument);
		@option_args = ();
	    } else {
		$NeedHints = 0;
	    }

	} elsif ($option eq "+om") {
	    $argument = join(" ", @option_args);
	    $argument ~~ s/ +$//;
	    $argument .= ";" unless $argument ~~ /[;{]$/;
	    @option_args = ();
	    if ($last_n_or_d ~~ /^-d (.+)/) {
		$Master_Zone_Opt{$1} .= "$argument\n";
	    } elsif ($last_n_or_d ~~ /^-n /) {
		($tmp1 = $last_n_or_d) ~~ s/^-n //;
		foreach $tmp2 (split(' ', $tmp1)) {
		    $Master_Zone_Opt{$tmp2} .= "$argument\n";
		}
	    } elsif ($last_n_or_d eq "-n") {
		for ($j = ($#option_history - 1); $j > 0; $j--) {
		    next unless $option_history[$j] ~~ /^(?:[+](?:om|os))|-S$/;
		    $tmp1 = $option_history[$j];
		    $tmp2 = $j + 1;
		    last;
		}
		$tmp = scalar(@option_history);
		print STDERR "Improper +om option (#$tmp in the option list).",
			     "\n",
			     "This option becomes position-dependent once a ",
			     "-d/-n option is specified.\n",
			     "The prior position-dependent option ",
			     "($tmp1, #$tmp2) has already cleared the\n",
			     "previous instance of -d/-n options.\n";
		GIVE_UP() unless defined wantarray;
		$message_count++;
	    } else {
		push(@Global_Master_Zone_Opts, $argument);
	    }

	} elsif ($option eq "+os") {
	    $argument = join(" ", @option_args);
	    $argument ~~ s/ +$//;
	    $argument .= ";" unless $argument ~~ /[;{]$/;
	    @option_args = ();
	    if ($last_n_or_d ~~ /^-d (.+)/) {
		$Slave_Zone_Opt{$1} .= "$argument\n";
	    } elsif ($last_n_or_d ~~ /^-n /) {
		($tmp1 = $last_n_or_d) ~~ s/^-n //;
		foreach $tmp2 (split(' ', $tmp1)) {
		    $Slave_Zone_Opt{$tmp2} .= "$argument\n";
		}
	    } elsif ($last_n_or_d eq "-n") {
		for ($j = ($#option_history - 1); $j > 0; $j--) {
		    next unless $option_history[$j] ~~ /^(?:[+](?:om|os))|-S$/;
		    $tmp1 = $option_history[$j];
		    $tmp2 = $j + 1;
		    last;
		}
		$tmp = scalar(@option_history);
		print STDERR "Improper +os option (#$tmp in the option list).",
			     "\n",
			     "This option becomes position-dependent once a ",
			     "-d/-n option is specified.\n",
			     "The prior position-dependent option ",
			     "($tmp1, #$tmp2) has already cleared the\n",
			     "previous instance of -d/-n options.\n";
		GIVE_UP() unless defined wantarray;
		$message_count++;
	    } else {
		push(@Global_Slave_Zone_Opts, $argument);
	    }

	} elsif ($option eq "-P") {
	    eval { require Tie::CPHash; };
	    if ($@) {
		print STDERR "Ignoring -P option; the required Tie::CPHash ",
			     "Perl module is not installed.\n";
		$message_count++;
	    } else {
		$Preserve_Case = 1;
	    }

	} elsif ($option eq "-p") {
	    #
	    # NOTE: The historical behavior of `-p' option processing
	    #       was to append the `-d' domain to all single-label
	    #       names.  This prevented the `-p' option from working
	    #       with Top-Level Domains (TLDs).  To maintain backwards
	    #       compatibility, TLDs must be distinguished by being
	    #       absolute domain names, i.e., being terminated by a
	    #       "." character.
	    #
	    while (@option_args) {
		$current_arg = shift(@option_args);
		if ($current_arg ~~ /^mode=/i) {
		    print STDERR "Improper -p option; a domain name must ",
				 "precede the `$current_arg' argument.\n";
		    GIVE_UP() unless defined wantarray;
		    $message_count++;
		    last;
		}
		if (length($current_arg) == 0
		    || CHECK_NAME($current_arg, 'SOA')) {
		    print STDERR "Improper -p option; the domain name ",
				 "`$current_arg' is invalid.\n";
		    GIVE_UP() unless defined wantarray;
		    $message_count++;
		    last;
		}
		unless ($current_arg ~~ /[.]/) {
		    unless ($Domain) {
			print STDERR "Improper -p option; the single-label ",
				     "non-absolute domain name of ",
				     "`$current_arg'\n",
				     "requires that the -d option be ",
				     "previously specified so that\n",
				     "the default domain name can be ",
				     "appended.\n";
			GIVE_UP() unless defined wantarray;
			$message_count++;
			last;
		    } else {
			#
			# Append the -d Domain to any domain argument
			# that is a single-label non-absolute name.
			#
			$domain_arg = "$current_arg.$Domain";
		    }
		} else {
		    #
		    # The domain argument is a multi-label domain name
		    # or a single-label absolute TLD (Top-Level Domain).
		    #
		    ($domain_arg = $current_arg) ~~ s/[.]$//;
		}
		($pattern = lc($domain_arg)) ~~ s/[.]/\\./g;
		if (exists($PTR_Pat_Rel{$pattern})) {
		    print STDERR "Improper -p option; the domain ",
				 "$current_arg' has\n",
				 "already been specified in a prior -p option.",
				 "\n";
		    GIVE_UP() unless defined wantarray;
		    $message_count++;
		    last;
		}
		$PTR_Pat_Rel{$pattern} = $domain_arg;
		push(@p_Opt_Patterns, $pattern);
		$p_Opt_Mode_Spec{$pattern} = "";	# a `mode=' argument
							# may update this later

		# See if there's an optional `mode=' argument.
		#
		if (@option_args && $option_args[0] ~~ /^mode=/i) {
		    $token = shift(@option_args);
		    ($argument = uc($token)) ~~ s/^MODE=//;
		    $argument ~~ s/[,]//g;
		    #
		    # Accept "D" as a valid flag for consistency with the +m
		    # option and the "[mh= ]" comment flag in the host file.
		    # Silently ignore it, however.
		    #
		    unless ($argument ~~ /^(?:A|D|AD|DA|P)$/) {
			print STDERR "Improper `$token' argument in -p option.",
				     "\n",
				     "The component of a valid `mode=' value ",
				     "is either `A' or `P'.\n";
			GIVE_UP() unless defined wantarray;
			$message_count++;
			last;
		    }
		    $argument ~~ s/D//;
		    #
		    # Update the mode-tracking hash with the actual flag(s).
		    #
		    $p_Opt_Mode_Spec{$pattern} = $argument;
		}
	    }

	} elsif ($option eq "-q") {
	    $Verbose = 0;

	} elsif ($option eq "-r") {
	    $Do_RP = 1;

	} elsif ($option eq "-S") {
	    $error = 0;
	    if ($last_n_or_d eq "") {
		$tmp = scalar(@option_history);
		print STDERR "Improper -S option (#$tmp in the option list).\n",
			     "This is a position-dependent option that ",
			     "applies to the preceding\n",
			     "-d/-n option(s).  No such -d/-n options have ",
			     "yet been specified.\n";
		$error = 1;
	    } elsif ($last_n_or_d eq "-n") {
		for ($j = ($#option_history - 1); $j > 0; $j--) {
		    next unless $option_history[$j] ~~ /^(?:[+](?:om|os))|-S$/;
		    $tmp1 = $option_history[$j];
		    $tmp2 = $j + 1;
		    last;
		}
		$tmp = scalar(@option_history);
		print STDERR "Improper -S option (#$tmp in the option list).\n",
			     "This is a position-dependent option that ",
			     "applies to the preceding\n",
			     "-d/-n option(s).  The prior position-dependent ",
			     "option ($tmp1, #$tmp2)\n",
			     "has already cleared the previous instance ",
			     "of -d/-n options.\n";
		$error = 1;
	    }
	    if ($error) {
		GIVE_UP() unless defined wantarray;
		$message_count++;
		next;
	    }
	    while (@option_args) {
		$argument = shift(@option_args);
		if ($argument ~~ /$IPv4_pattern/o) {
		    print STDERR "Uh, the -S option requires a domain name, ",
				 "not an IP address.\n";
		    GIVE_UP() unless defined wantarray;
		    $message_count++;
		    last;
		} elsif ($last_n_or_d ~~ /^-d (.+)/) {
		    $Partial_Servers{$1} .= " $argument";
		} elsif ($last_n_or_d ~~ /^-n /) {
		    ($tmp1 = $last_n_or_d) ~~ s/^-n //;
		    foreach $tmp2 (split(' ', $tmp1)) {
			$Partial_Servers{$tmp2} .= " $argument";
		    }
		}
	    }

	} elsif ($option eq "+S") {
	    $argument = "";
	    if (@option_args) {
		$argument = shift(@option_args);
		if ($argument ~~ /^(?:no|false|off|none|disable)$/i) {
		    $default_supernetting = 0;
		} elsif ($argument ~~ /^(?:yes|true|on|enable)$/i) {
		    $default_supernetting = 1;
		} else {
		    if ($Verbose) {
			$flag = ($default_supernetting) ?? "enabled"
							!! "disabled";
			print STDERR "Unknown `+S' argument (`$argument'); ",
				     "supernetting remains $flag.\n";
			$message_count++;
		    }
		}
	    }
	    unless ($argument) {
		if ($default_supernetting && $Verbose) {
		    print STDERR "Redundant +S option with no argument; ",
				 "supernetting remains enabled.\n";
		    $message_count++;
		}
		$default_supernetting = 1;
	    }

	} elsif ($option eq "-s") {
	    while (@option_args) {
		$argument = shift(@option_args);
		if ($argument ~~ /$IPv4_pattern/o) {
		    print STDERR "Uh, the -s option requires a domain name, ",
				 "not an IP address.\n";
		    GIVE_UP() unless defined wantarray;
		    $message_count++;
		    last;
		} else {
		    push(@Full_Servers, $argument);
		}
	    }

	} elsif ($option eq "-T") {
	    while (@option_args) {
		$argument = shift(@option_args);
		if ($argument ~~ /^mode=M/i) {
		    $Do_Zone_Apex_MX = 1;
		} elsif ($argument ~~ /^ALIAS=/i) {
		    ($domain_arg = $argument) ~~ s/^ALIAS=//i;
		    unless (length($domain_arg)) {
			print STDERR "Improper -T option; the `ALIAS=' ",
				     "keyword requires a domain name ",
				     "as an argument.\n";
			GIVE_UP() unless defined wantarray;
			$message_count++;
			last;
		    }
		    ($domain_arg, $ttl) = split(' ', $domain_arg, 2);
		    $ttl = "" unless defined($ttl);
		    if (exists($Apex_Aliases{lc($domain_arg)})) {
			if ($Verbose) {
			    print STDERR "Improper -T option; duplicate ",
					 "argument `$argument' ignored.\n";
			}
			$message_count++;
		    } elsif ($ttl && $ttl !~ /^(?:\d+|(?:\d+[wdhms])+)$/i) {
			print STDERR "Improper -T option; invalid TTL ",
				     "in argument `$argument'.\n";
			GIVE_UP() unless defined wantarray;
			$message_count++;
			last;
		    } else {
			$Apex_Aliases{lc($domain_arg)} = "$domain_arg $ttl";
		    }
		} elsif ($argument ~~ /^RR=/i) {
		    ($token = $argument) ~~ s/^RR=//i;
		    unless (length($token)) {
			print STDERR "Improper -T option; the `RR=' keyword ",
				     "requires a DNS record as an argument.\n";
			GIVE_UP() unless defined wantarray;
			$message_count++;
			last;
		    }
		    $error = "";
		    if ($token ~~ /^(.*?\s)($RRtypes)\s+(.+)/io) {
			$tmp1 = $1;
			$rrtype = uc($2);
			$rdata = $3;
			$tmp1 ~~ s/(?:\s+IN)?\s+$//i;	# strip `IN' if present
			$domain_arg = '@';		# set to default value
			if ($tmp1 ~~ /^\S/) {		# $ttl *may* be null
			    ($domain_arg, $ttl) = split(' ', $tmp1, 2);
			    $ttl = "" unless defined($ttl);
			    1 while $domain_arg ~~ s/\\\\/\\/g;
			} elsif ($tmp1 ~~ /\S/) {	# $ttl is *not* null
			    ($ttl = $tmp1) ~~ s/\s+//g;
			} else {			# $ttl *is* null
			    $ttl = "";
			}
			if ($domain_arg ne '@'
			    && lc($domain_arg) ne lc("$Domain.")) {
			    $error = "the `RR=' owner field must "
				   . "be `\@' if specified.";
			} elsif ($rrtype eq 'SOA') {
			    $error = "the SOA record is configured "
				   . "with -h/-i/-o/+t/-u/-y.";
			} elsif ($rrtype eq 'NS') {
			    $error = "zone apex NS records may only "
				   . "be configured with -s/-S.";
			} elsif ($rrtype !~ /^(?:$apex_rrtypes)$/o) {
			    $error = "`$rrtype' is out of context "
			           . "as a zone apex RR type.";
			} elsif ($ttl && $ttl !~ /^(?:\d+|(?:\d+[wdhms])+)$/i) {
			    $error = "invalid TTL ($ttl).";
			}
		    } else {
			$error = "the `RR=' argument has a bad format "
			       . "or an unknown RR type.";
		    }
		    if ($error) {
			print STDERR "Improper -T option; $error\n";
			$argument ~~ s/=.*//;
			print STDERR "> $argument='$token'\n";
			GIVE_UP() unless defined wantarray;
			$message_count++;
			last;
		    }
		    $continuation_line = $open_paren_count = $open_quote = 0;
		    while ($continuation_line || $rdata ~~/["()]/) {
			#
			# Accommodate the possibility that the -T option
			# may specify a multi-line resource record, e.g.,
			#
			#   -T RR=" WKS 192.249.239.3  TCP ( telnet smtp"
			#         "                    ftp shell domain)"
			#   -T RR=' TXT "First line of text\'
			#         'second line of text."'
			#
			# NOTE: The shell and/or the -f option has already
			#       ensured that any quotes needed to protect
			#       whitespace or other special characters in
			#       the "@args" argument stream are already
			#       balanced.  These 'outer' quotes are
			#       effectively removed as each argument is
			#       assembled and thus are not seen here.
			#       Unescaped "inner" quotes that are part of
			#       an RDATA field, however, are seen and
			#       accounted for by the -T option.  Unbalanced
			#       quotes and/or parentheses will cause subsequent
			#       arguments to be appended until balance is
			#       achieved or there are no more arguments left
			#       in "@args".
			#
			$token = $rdata;
			$last_char = "";
			while (length($token)) {
			    ($char, $token) = split(//, $token, 2);
			    if ($char eq "\\" && $last_char eq "\\") {
				#
				# An escape character which is itself escaped
				# becomes an ordinary backslash character.
				# Remove its ability to escape the next
				# character in the byte stream.
				#
				$last_char = "";
				next;
			    }
			    unless ($open_quote || $last_char eq "\\") {
				last if $char eq ";";
				if ($char eq "\(") {
				    $open_paren_count++;
				    #
				    # Maintain a stack of arguments which have
				    # open quotes and/or parentheses.  Arguments
				    # are popped from the stack as the balancing
				    # characters are read.  Leftover arguments
				    # on the stack are reported along with the
				    # appropriate error message to help locate
				    # the source of the imbalance.
				    #
				    $j = $#unbalanced_args;
				    if ($j < 0
					|| $unbalanced_args[$j][0] ne $rdata) {
					push(@unbalanced_args, [ $rdata, 0 ]);
				    } else {
					$unbalanced_args[$j][1]++;
				    }
				} elsif ($char eq "\)") {
				    $open_paren_count--;
				    $j = $#unbalanced_args;
				    if ($open_paren_count < 0) {
					@unbalanced_args = ();
					push(@unbalanced_args, $rdata);
					last;
				    }
				    if ($unbalanced_args[$j][1]) {
					$unbalanced_args[$j][1]--;
				    } else {
					pop(@unbalanced_args);
				    }
				}
			    }
			    if ($char eq '"' && $last_char ne "\\") {
				$open_quote = !$open_quote;
				$j = $#unbalanced_args;
				if ($open_quote) {
				    if ($j < 0
					|| $unbalanced_args[$j][0] ne $rdata) {
					push(@unbalanced_args, [ $rdata, 0 ]);
				    } else {
					$unbalanced_args[$j][1]++;
				    }
				} else {
				    if ($unbalanced_args[$j][1]) {
					$unbalanced_args[$j][1]--;
				    } else {
					pop(@unbalanced_args);
				    }
				}
			    }
			    $last_char = $char;

			}
			if ($continuation_line) {
			    #
			    # Append a newline as a way of signaling FIXUP()
			    # and MAKE_SOA() that this is a multi-line record.
			    # A second newline is appended if an open quote
			    # is in effect when the line break occurs.
			    #
			    $rdata .= "\n";
			    $rdata .= "\n" if $continuation_line == 2;
			} else {
			    #
			    # Prepend the record's TTL to the beginning
			    # of each new RR.
			    #
			    $rdata = "$ttl,$rdata";
			}
			push(@{ $Apex_RRs{$rrtype} }, $rdata);
			unless ($open_quote || $open_paren_count) {
			    $rdata = "";
			    $continuation_line = 0;
			} elsif ($open_paren_count < 0) {
			    $error  = "found `RR=' argument with a misplaced "
				    . "closing parenthesis:\n";
			    $error .= "> `$unbalanced_args[0]'";
			    last;
			} else {
			    #
			    # Get the next token in the PARSE_ARGS() argument
			    # vector provided there is one that's available.
			    #
			    if (@option_args) {
				$continuation_line = ($open_quote) ?? 2 !! 1;
				$rdata = shift(@option_args);
			    } else {
				if (!$open_quote) {
				    $tmp1 = "parentheses.\n";
				} elsif (!$open_paren_count) {
				    $tmp1 = "quotes.\n";
				} else {
				    $tmp1 = "parentheses and\nquotes.  ";
				}
				$error = "found `RR=' argument(s) with "
				       . "unbalanced $tmp1"
				       . "Ran out of arguments before the "
				       . "following item(s) could be balanced:";
				for $j (0 .. $#unbalanced_args) {
				    $error .= "\n> `$unbalanced_args[$j][0]'";
				}
				last;
			    }
			}
		    }
		    if ($error) {
			print STDERR "Improper -T option; $error\n";
			GIVE_UP() unless defined wantarray;
			$message_count++;
			last;
		    } elsif ($rdata) {
			#
			# An ordinary single-line RR was specified.
			#
			push(@{ $Apex_RRs{$rrtype} }, "$ttl,$rdata");
		    }
		} else {
		    print STDERR "Improper -T option; argument `$argument' ",
				 "is unrecognized.\n",
				 "                    Must be one of mode=M, ",
				 "RR=, and/or ALIAS=\n";
		    GIVE_UP() unless defined wantarray;
		    $message_count++;
		    last;
		}

	    }

	} elsif ($option eq "-t") {
	    $Do_TXT = 1;
	    $argument = join("", @option_args);
	    $argument ~~ s/^mode=//i;
	    $argument ~~ s/[,]//g;
	    unless ($argument) {
		if (($Quoted_Txt_Only || $Quoted_Txt_Preferred) && $Verbose) {
		    print STDERR "Hmm, default -t option cancels previously ",
				 "specified `O' and/or `P' argument(s).\n";
		    $message_count++;
		}
		$Quoted_Txt_Only = $Quoted_Txt_Preferred = 0;
	    } else {
		unless ($argument ~~ /^(?:O|P|OP|PO)$/i) {
		    print STDERR "Improper `$argument' argument in -t option.",
				 "\n",
				 "Valid argument must be one of: O, P, or OP.",
				 "\n";
		    GIVE_UP() unless defined wantarray;
		    $message_count++;
		} else {
		    $argument = uc($argument);
		    if (($Quoted_Txt_Only || $Quoted_Txt_Preferred)
			&& $Verbose) {
			print STDERR "Hmm, using `-t $argument' to override ",
				     "previous -t option.\n";
			$message_count++;
		    }
		    $Quoted_Txt_Only      = 1 if $argument ~~ /[O]/i;
		    $Quoted_Txt_Preferred = 1 if $argument ~~ /[P]/i;
		}
		@option_args = ();
	    }

	} elsif ($option eq "+t") {
	    $argument = shift(@option_args);
	    unless ($argument ~~ /^(?:\d+|(?:\d+[wdhms])+)$/i) {
		print STDERR "Improper +t option `$argument' ",
			     "for DEFAULT-TTL.\n";
		GIVE_UP() unless defined wantarray;
		$message_count++;
		next;
	    } else {
		$Master_Ttl = $argument;
	    }
	    if (@option_args) {
		$argument = shift(@option_args);
		unless ($argument ~~ /^(?:\d+|(?:\d+[wdhms])+)$/i) {
		    print STDERR "Improper +t option `$argument' ",
				 "for MINIMUM-TTL.\n";
		    GIVE_UP() unless defined wantarray;
		    $message_count++;
		    next;
		} else {
		    $Ttl = $argument;
		}
	    } else {
		$Ttl = $DefNegCache;
	    }
	    if (!$RFC_2308 && $Verbose) {
		print STDERR "Hmm, using `+t $Master_Ttl $Ttl' ",
			     "to override previous -o option.\n";
		$message_count++;
	    }
	    # NOTE: Once the `+t' option is specified, our RFC-2308 status
	    #       can not be undone by a subsequent four-argument `-o'
	    #       option, e.g., `-o :::', in this subroutine (PARSE_ARGS).
	    #       The "$RFC_2308" flag is set to a "hard" value of 2.
	    #       The only way for non-RFC-2308 status to be asserted now,
	    #       i.e., "$RFC_2308" = 0, is if the FIXUP() subroutine detects
	    #       that a pre-8.2 version of BIND is running on the master
	    #       name server (-h option).
	    #
	    $RFC_2308 = 2;
	    if ($Verbose) {
		$message_count++ if CHECK_SOA_TIMERS();
	    }

	} elsif ($option eq "-u") {
	    $argument = shift(@option_args);
	    if ($argument eq '@') {
		$argument = "root";
		if ($Verbose) {
		    print STDERR "`\@' is not acceptable for the -u option; ",
				 "substituting `root' instead.\n"
		}
		$message_count++;
	    }
	    $User = $argument;

	} elsif ($option eq "-V") {
	    $Verify_Mode = 1;
	    while (@option_args) {
		$argument = lc(shift(@option_args));
		#
		# Append the root zone as a trailing dot and then
		# make sure that there is only one such dot.
		#
		$argument .= ".";
		$argument ~~ s/[.]+$/./;
		if (length($argument) >= 1 && CHECK_NAME($argument, 'SOA')) {
		    print STDERR "Improper -V option; the domain name ",
				 "`$argument' is invalid.\n";
		    GIVE_UP() unless defined wantarray;
		    $message_count++;
		    last;
		}
		#
		# Stack the domains with the unshift() function so that they
		# can be popped in the same order.  This allows child domains
		# to be pushed onto the stack during processing and thus grouped
		# with the parent domain if recursive verification is enabled.
		# The initial recursion depth (already initialized to zero) is
		# also stacked in case the `-recurse' option is specified with
		# a depth limit.
		#
		unless (exists($duplicate{$argument})) {
		    unshift(@V_Opt_Domains, $argument, $Recursion_Depth);
		    $duplicate{$argument} = 1;
		}
	    }

	} elsif ($option ~~ /^-v([:=](.*))?$/) {
	    #
	    # This option has two functions.  The documented one is to
	    # report the version number of `h2n'.  The undocumented
	    # function is to set the "$BIND_Version" variable as an aid
	    # in debugging the BIND bugs reported by GET_BIND_VERSION().
	    #
	    if (defined $2) {
		$Debug_BIND_Version = $2;
	    } elsif (@option_args) {
		$Debug_BIND_Version = shift(@option_args);
	    } else {
		print STDOUT "This is $0 v$VERSION\n";
		exit(0) unless defined wantarray;
	    }

	} elsif ($option eq "-W") {
	    #
	    # NOTE: Prior to version 2.60, the -W option was of limited use
	    #       and rather inconsistent.  Zone data and `spcl' files
	    #       were searched/read/written only in the current working
	    #       directory.  However, the -W directory was inserted into
	    #       the $INCLUDE directives for `spcl' files and the `directory'
	    #       statements of the generated /boot/conf files.
	    #
	    #       As of v2.60, not only will the -W option retain its presence
	    #       in $INCLUDE directives and `directory' statements, `h2n'
	    #       will use the -W directory as its exclusive work area to look
	    #       for `spcl' files and to read and write the zone data files.
	    #       The original behavior prior to this change can be restored
	    #       by specifying the `mode=O' argument.
	    #
	    $DB_Dir = shift(@option_args);
	    1 while $DB_Dir ~~ s/\/\//\//g;
	    $DB_Dir ~~ s/(.)\/$/$1/;
	    $DB_Dir = $cwd if $DB_Dir eq ".";
	    $error = 0;
	    unless ($DB_Dir ~~ /^\//) {
		print STDERR "Must use an absolute pathname ",
			     "for the -W option.\n";
		$error = 1;
	    } elsif (!-d $DB_Dir || !-r _ || !-w _) {
		print STDERR "Improper -W option ($DB_Dir).\n",
			     "The specified directory is non-existent, ",
			     "invalid, or has no read/write access.\n";
		$error = 1;
	    }
	    unless ($error) {
		#
		# See if there's an optional `mode=' argument.
		#
		if (@option_args) {
		    $token = shift(@option_args);
		    unless ($token ~~ /^mode=/i) {
			print STDERR "Improper `$token' argument in -W option.",
				     "\n",
				     "Expected to see `MODE=O'.\n";
			$error = 1;
		    } else {
			($argument = uc($token)) ~~ s/^MODE=//;
			unless ($argument eq "O") {
			    print STDERR "Improper `$token' argument in ",
					 "-W option.\n",
					 "The component of a valid `mode=' ",
					 "value must be `O'.\n";
			    $error = 1;
			} else {
			    $Search_Dir = $cwd;
			}
		    }
		}
	    }
	    if ($error) {
		GIVE_UP() unless defined wantarray;
		$message_count++;
	    }

	} elsif ($option eq "-w") {
	    $Do_WKS = 1;

	} elsif ($option eq "-X") {
	    $Conf_Only = 1;

	} elsif ($option eq "-y") {
	    $argument = "D";
	    $error = 0;
	    if (defined($New_Serial) && !$UseDateInSerial) {
		print STDERR "Improper -y option; it is incompatible ",
			     "with the already-specified -i option.\n";
		$error = 1;
	    } elsif (@option_args) {
		#
		# See if there's an optional `mode=' argument.
		#
		$token = shift(@option_args);
		unless ($token ~~ /^mode=/i) {
		    print STDERR "Improper `$token' argument in -y option.\n",
				 "Expected to see `MODE=[D|M]'.\n";
		    $error = 1;
		} else {
		    ($argument = uc($token)) ~~ s/^MODE=//;
		    unless ($argument ~~ /^[DM]$/) {
			print STDERR "Improper `$token' argument in -y option.",
				     "\n",
				     "The component of a valid `mode=' value ",
				     "is either `D' or `M'.\n";
			$error = 1;
		    }
		}
	    }
	    if ($error) {
		GIVE_UP() unless defined wantarray;
		$message_count++;
	    } elsif ($argument ~~ /^[DM]$/) {
		@ctime = localtime(time);
		$New_Serial = (($ctime[5] + 1900) * 1000000)
			    + (($ctime[4] + 1) * 10000);
		if ($argument eq "M") {
		    $UseDateInSerial = 1;
		} else {
		    $UseDateInSerial = ($ctime[3] * 100);
		    $New_Serial += $UseDateInSerial;
		}
	    }

	} elsif ($option eq "-Z") {
	    while (@option_args) {
		$argument = shift(@option_args);
		if ($argument !~ /$IPv4_pattern/o) {
		    print STDERR "Improper IP address [$argument] ",
				 "in -Z option.\n";
		    GIVE_UP() unless defined wantarray;
		    $message_count++;
		    last;
		}
		if (defined($BootSecAddr)) {
		    $BootSecAddr .= " " . $argument;
		} else {
		    $BootSecAddr = $argument;
		}
		if (defined($ConfSecAddr)) {
		    $ConfSecAddr .= " " . $argument . ";";
		} else {
		    $ConfSecAddr = $argument . ";";
		}
	    }

	} elsif ($option eq "-z") {
	    while (@option_args) {
		$argument = shift(@option_args);
		if ($argument !~ /$IPv4_pattern/o) {
		    print STDERR "Improper IP address [$argument] ",
				 "in -z option.\n";
		    GIVE_UP() unless defined wantarray;
		    $message_count++;
		    last;
		}
		if (defined($BootSecSaveAddr)) {
		    $BootSecSaveAddr .= " " . $argument;
		} else {
		    $BootSecSaveAddr = $argument;
		}
		if (defined($ConfSecSaveAddr)) {
		    $ConfSecSaveAddr .= " " . $argument . ";";
		} else {
		    $ConfSecSaveAddr = $argument . ";";
		}
	    }

	} elsif ($option eq 'recurse') {
	    #
	    # Causes each child domain to be verified immediately
	    # after completing verification of the parent domain.
	    # An optional argument can also be specified to limit
	    # how many delegation levels will be followed for each
	    # domain supplied to the -V option.
	    #
	    if ($option_value) {
		$argument = $option_value;
	    } elsif (@option_args) {
		$argument = shift(@option_args);
	    } else {
		undef $argument;
	    }
	    $Recursive_Verify = ($option_modifier eq 'no') ?? 0 !! 1;
	    if ($Recursive_Verify && defined($argument)) {
		unless ($argument ~~ /^\d+$/) {
		    print STDERR "Improper $original_option option; limit ",
				 "argument must be a non-negative integer.\n";
		    GIVE_UP() unless defined wantarray;
		    $message_count++;
		} else {
		    $Recursion_Limit = $argument;
		}
	    } else {
		#
		# Make sure that "$Recursion_Limit" is undefined, i.e,
		# unlimited, in case no limit argument was specified.
		#
		undef $Recursion_Limit;
	    }

	} elsif ($option eq 'check-del') {
	    #
	    # Bypasses the checking of proper delegations with the
	    # `check_del' program when in verify mode.  `check_del'
	    # can be quite time-consuming when encountering a large
	    # number of unresponsive name servers.
	    #
	    $Verify_Delegations = ($option_modifier eq 'no') ?? 0 !! 1;

	} elsif ($option eq 'single-ns') {
	    #
	    # Bypasses the check to see if a delegation is made to
	    # at least two name servers as suggested by RFC-1034.
	    #
	    $Show_Single_Delegations = ($option_modifier ~~ /(?:no-show|hide)/)
				     ?? 0 !! 1;

	} elsif ($option eq 'query-external-domains') {
	    #
	    # Bypasses making DNS queries for domain names that are
	    # external to the zone being processed (-d/-V option) since
	    # it can be quite time-consuming when encountering a large
	    # number of lame, slow, and/or unresponsive name servers.
	    #
	    $Query_External_Domains = ($option_modifier eq 'no') ?? 0 !! 1;

	} elsif ($option eq 'dangling-cnames') {
	    #
	    # CNAMEs that point to non-existent domain names, i.e.,
	    # "dangling CNAMEs", are not generally considered to be
	    # DNS errors.  This is especially true in the context
	    # of RFC-2317 delegations of sub-class-C `in-addr.arpa'
	    # zones where each CNAME placeholder does not necessarily
	    # point to an existing domain name having a PTR record.
	    # For forward-mapping zones, however, it may be of interest
	    # to know if a CNAME has become obsolete if the out-of-zone
	    # domain name to which it points no longer longer exists.
	    #
	    # One or more domain names may be specified by this option
	    # in order to limit the display to only matching domains
	    # (show/no-hide) or to exclude their display (no-show/hide).
	    #
	    $option_modifier = ($option_modifier ~~ /(?:no-show|hide)/) ?? 0 !! 1;
	    $flag = scalar(@option_args);
	    while (@option_args) {
		$argument = shift(@option_args);
		if (length($argument) == 0 || CHECK_NAME($argument, 'SOA')) {
		    print STDERR "Improper $original_option option; the ",
				 "domain name `$argument' is invalid.\n";
		    GIVE_UP() unless defined wantarray;
		    $message_count++;
		    last;
		}
		($tmp = lc($argument)) ~~ s/[.]$//;
		$tmp ~~ s/[.]/\\./g;
		if (exists($Dangling_CNAME_Domains{$tmp}) && $Verbose) {
		    if ($Dangling_CNAME_Domains{$tmp} != $option_modifier) {
			$tmp1 = ($option_modifier == 0) ?? "show" !! "hide";
			print STDERR "Warning: $original_option option; ",
				     "reversing the context (from `$tmp1')\n",
				     "         of the previously specified ",
				     "domain name `$argument'.\n";
		    } else {
			print STDERR "Improper $original_option option; ",
				     "duplicate argument `$argument' ignored.",
				     "\n";
		    }
		    $message_count++;
		}
		$Dangling_CNAME_Domains{$tmp} = $option_modifier;
	    }
	    unless($flag) {
		#
		# Allow "$Show_Dangling_CNAMEs" variable to be defined
		# as a global flag only if there were no domain name
		# arguments present for this option.
		#
		if (defined($Show_Dangling_CNAMEs)
		    && $Show_Dangling_CNAMEs != $option_modifier && $Verbose) {
		    $tmp1 = ($option_modifier == 0) ?? "show" !! "hide";
		    print STDERR "Warning: $original_option option; reversing ",
				 "the context\n",
				 "         (from `$tmp1') of the previous ",
				 "specification.\n";
		    $message_count++;
		}
		$Show_Dangling_CNAMEs = $flag;
	    }

	} elsif ($option eq 'chained-cnames') {
	    #
	    # The length of out-of-zone CNAME chains are normally
	    # displayed only if the CNAME ultimately fails to resolve
	    # to a non-CNAME domain name.  This option overrides the
	    # default behavior by identifying all instances of
	    # out-of-zone CNAME chains.
	    #
	    $Show_Chained_CNAMEs = ($option_modifier ~~ /(?:no-show|hide)/) ?? 0
									    !! 1;

	} elsif ($option eq 'debug') {
	    #
	    # Prevents the removal of all temporary files that get
	    # created during the course of normal processing including
	    # zone transfer files:
	    #
	    #  * If zone auditing is in effect, the DiG batch input file
	    #    is saved as well as a copy of the answers to the queries.
	    #  * If delegations are being verified, the complete input and
	    #    output of the `check_del' program is also saved.
	    #  * If a domain is being verified and the zone transfer file
	    #    still exists from a previous run with -debug, the existing
	    #    zone transfer data will be used instead of requesting a
	    #    new copy from an authoritative name server.
	    #
	    # An alternate directory to `/tmp' may be specified by using
	    # the format `-debug[:=]directory' or `-debug directory'.
	    # The directory must exist and the user running `h2n' must
	    # have read/write access.
	    #
	    if ($option_value) {
		$Debug_DIR = $option_value;
	    } elsif (@option_args) {
		$Debug_DIR = shift(@option_args);
	    } else {
		undef $Debug_DIR;
	    }
	    $Debug = ($option_modifier eq 'no') ?? 0 !! 1;
	    unless (defined($Debug_DIR)) {
		$Debug_DIR = "/tmp";
	    } else {
		$Debug_DIR ~~ s/\/+$//;
		$Debug_DIR = "/" if $Debug_DIR eq "";
		unless (-d $Debug_DIR) {
		    if ($Verbose) {
			print STDERR "`$Debug_DIR' argument of ",
				     "$original_option must be a directory; ",
				     "ignored.\n";
			$message_count++;
		    }
		    $Debug_DIR = "/tmp";
		} elsif (!-r $Debug_DIR || !-w _) {
		    if ($Verbose) {
			print STDERR "`$Debug_DIR' argument of ",
				     "$original_option requires R/W access; ",
				     "ignored.\n";
			$message_count++;
		    }
		    $Debug_DIR = "/tmp";
		}
		$Debug_DIR = "" if $Debug_DIR eq "/";
	    }

	} elsif ($option eq 'glue-level') {
	    #
	    # Display (if no argument) or specify the number (ranging from
	    # zero to "$Glueless_Upper_Limit") of chained inter-subzone
	    # delegations that are permitted before optional glue records in
	    # the parent zone are considered to become mandatory.  This does
	    # not override the absolute necessity of glue records for name
	    # servers which are themselves located in the same delegated
	    # subdomain.
	    #
	    # If left unspecified, the FIXUP() subroutine will initialize the
	    # global "$Glueless_Limit" variable from one of the following
	    # default variables depending on the operating mode of `h2n':
	    #
	    #   "$DB_Glueless_Limit" sets the maximum number of glueless
	    #   subdomain delegations that are permitted in a `spcl' file
	    #   when `h2n' is building zone data files from a host table.
	    #   Exceeding the limit will generate a warning about missing glue.
	    #   The built-in default value is set to a conservative value of 1.
	    #
	    #   "$Verify_Glueless_Limit" sets the limit of chained gluelessness
	    #   that is tolerated when verifying an existing zone data file.
	    #   The built-in default value is set to a more liberal but still
	    #   realistic value of 3.
	    #
	    # Both of above built-in defaults can be customized via settings
	    # in the `h2n.conf' configuration file.
	    #
	    if ($option_value) {
		$argument = $option_value;
	    } elsif (@option_args) {
		$argument = shift(@option_args);
	    } else {
		undef $argument;
	    }
	    unless (defined($argument)) {
		#
		# The operational glueless limit will be displayed by FIXUP()
		# when the operating mode ("$Verify_Mode" flag) is known.
		#
		$Display_Glueless_Limit = 1;
	    } else {
		$Display_Glueless_Limit = 0;
		unless ($argument ~~ /^\d+$/
			&& $argument <= $Glueless_Upper_Limit) {
		    print STDERR "Improper $original_option option; argument ",
				 "must be a number in the range ",
				 "0-$Glueless_Upper_Limit.\n";
		    GIVE_UP() unless defined wantarray;
		    $message_count++;
		} else {
		    $Glueless_Limit = $argument;
		}
	    }

	} elsif ($option eq 'help') {
	    $j = $Glueless_Upper_Limit;		# utilize a short variable name
	    print STDOUT <<"EOT";
Usage:  h2n [zone creation options] | -V [zone verification options]

The zone creation options are:
  -A Don't create name server data for aliases in the host table
  -a NET[:SUBNETMASK|/CIDRsize [mode=S]] [NET ...]
     Add hostname data on NET to -d DOMAIN but without PTR data
     mode=S  Allow /8-24 network to be a supernet to smaller-classed nets
  -B PATH
     Set absolute directory path where boot/conf files will be written
  -b BOOTFILE
     Use BOOTFILE instead of the default: ./named.boot (BIND 4)
  -C COMMENT-FILE
     Create RRs using special host file comments as keys into COMMENT-FILE
  +C PRE-CONFFILE
     Prepend contents of PRE-CONFFILE to the BIND 8/9 conf file (+c option)
  -c REMOTE-DOMAIN [mode=[A][I][D[Q]][HS]] [REMOTE-DOMAIN [mode=...]
     Add CNAMEs which point to REMOTE-DOMAIN
     mode=A  Create additional CNAMEs for aliases in REMOTE-DOMAIN
         =I  REMOTE-DOMAIN is an intra-zone subdomain of -d DOMAIN
         =D  Defer CNAMEs; name conflicts prefer -d DOMAIN over REMOTE-DOMAIN
         =Q  Don't report name conflicts that prevent deferred CNAME creation
         =H  enable -hide-dangling-cnames REMOTE-DOMAIN option
         =S  enable -show-dangling-cnames REMOTE-DOMAIN option
  +c [CONFFILE] [mode=S|M]
     Use CONFFILE instead of the default: ./named.conf (BIND 8/9)
     mode=S  Create CONFFILE with zone entries in single-line format (default)
         =M  Create CONFFILE with zone entries in multi-line format
  -D [FILE]
     Create delegation information to link in with your parent zones
  -d DOMAIN [db=FILE1] [spcl=FILE2] [mode=D|Q]
     Create zone data file for DOMAIN
     db=FILE1    Override default filename of db.LABEL, e.g., label.movie.edu
     spcl=FILE2  Override default filename of spcl.LABEL for existing RRs
     mode=D      Set default domain of unqualified hostnames to DOMAIN
         =Q      Silently ignore hostnames that do not match DOMAIN
  -e EXCLUDED-DOMAIN [EXCLUDED-DOMAIN]
     Exclude hostfile data with names in EXCLUDED-DOMAIN
  -f FILE
     Read command line options from FILE
  -H HOSTFILE
     Use HOSTFILE instead of /etc/hosts (read STDIN if HOSTFILE is `-')
  -h HOST
     Set HOST in the MNAME (master name server) field of the SOA record
  -I [ignore|warn|audit|audit-only|warn-strict|fail|strict] [rfc2782]
     Control level and type of various RFC conformance checks
     ignore       Disables checking of domain names and zone data consistency
     warn         Issue warning when hostnames contain illegal characters
     audit        Check zone data for integrity and RFC compliance + `warn'
     audit-only   Check zone data integrity without the `warn' check
     warn-strict  Warn about single-character hostnames + `warn' + `audit'
     fail         Reject hostnames with illegal characters + `audit'
     strict       Reject single-character hostnames + `fail' + `audit'
     rfc2782      Check SRV RRs for `_service._protocol' labels in owner names
  -i NUM
     Set the serial number of all created/updated zone files to NUM
  -L NUM
     Set file handle limit to NUM
  +L [LOG-SPEC]
     Add a logging specification to the BIND 8/9 config files
  -M [no-mx|smtp|no-smtp]
     Restrict the generation of MX records.  No argument means that MX
     records will not be generated under any circumstances.  Otherwise,
     set the default action which can be overridden on a host-by-host basis.
     no-mx    Do not generate any MX records
     smtp     Only generate the self-pointing MX record
     no-smtp  Only generate the global MX record(s) from -m option(s)
  -m WEIGHT:MX-HOST [WEIGHT:MX-HOST]
     Include MX record for each host not having [no mx]/[smtp] comment flags
  +m [D|C|P|CP]
     Control RR generation method for multi-homed hosts
     D   Use default behavior (A RRs for all names, CNAMEs for common aliases)
     C   Create A RRs for canonical name and 1st alias, CNAMEs for all others
     P   Create PTR RRs that point to A RR of 1st alias instead of canonical
     CP  Combine `C' and `P' flags
  -N SUBNETMASK|/CIDRsize
     Apply SUBNETMASK/CIDRsize as default value for subsequent -n/-a options
  -n NET[:SUBNETMASK|/CIDRsize [mode=S] [domain=DOMAIN] [ptr-owner=TEMPLATE]]
        [db=FILE1] [spcl=FILE2]
     Create zone data for each class-A/B/C subnet of NET for network sizes
     /8 to /24.  For /25-32 networks, create zone data to support RFC-2317
     delegations to DOMAIN with the owner names of the PTR records fitting
     the TEMPLATE pattern.
     mode=S      Allow /8-24 network to be a supernet to smaller-classed nets
     db=FILE1    Override default filename of db.NET, e.g., db.192.168.1
     spcl=FILE2  Override default filename of spcl.NET for existing RRs
  -O OPTION OPTION-ARGS
     Add option specifications to BIND 4 boot files
  +O [OPTION-SPEC]
     Add option specifications to BIND 8/9 conf files
  -o [REFRESH]:[RETRY]:[EXPIRE]:[MINIMUM]:[DEFAULT-TTL]
     Set SOA time intervals
 +om OPTION OPTIONS-ARGS
     Adds zone-specific options to BIND 8/9 master conf
 +os OPTION OPTIONS-ARGS
     Adds zone-specific options to BIND 8/9 slave conf
  -P Preserve upper-case characters of hostnames and aliases in the host table
  -p REMOTE-DOMAIN [mode=A|P] [REMOTE-DOMAIN [mode=...]
     Create only PTR data for REMOTE-DOMAIN hosts
     mode=A  Required flag if REMOTE-DOMAIN's forward-mapping zone built w/ -A
         =P  Enables alternate method of PTR generation as described for +m P
  -q Work quietly
  -r Enable creation of RP (Responsible Person) records
  -S SERVER [SERVER]
     Adds NS record to zone(s) for the last preceding -d option or -n option(s)
  +S [enable|disable]
     Control class-A/B/C NETs to act as supernets for subsequent -n/-a options
  -s SERVER [SERVER]
     Adds NS record to zones for -d option and all -n options
  -T [mode=M] [RR='DNS RR' [RR='...']] [ALIAS='name [TTL]' [ALIAS='...']]
     Add additional top-of-zone-related records to DOMAIN of the -d option
     mode=M  Add the global MX record(s) specified in the -m option
     RR=     Add 'DNS RR' with owner field set to whitespace or to `\@'
     ALIAS=  Add CNAME RR with owner field of 'name' & RDATA field set to `\@'
  -t [O|P]
     Generate TXT records from host table comment fields excluding h2n flags
     O   Only generate a TXT record if an explicitly quoted string is present
     P   Prefer explicitly quoted text but otherwise act in the default manner
  +t DEFAULT-TTL [MINIMUM-TTL]
     Create \$TTL directives & SOA Negative Cache TTL
  -u CONTACT
     Set CONTACT as the mail addr. in the SOA RNAME (responsible person) field
  -v Display the version number of h2n
  -W PATH [mode=O]
     Set absolute directory path where `spcl'/zone files will be read/written
     mode=O  Set old (pre-v2.60) behavior where PATH only appears in boot/conf
             `directory' statements and `spcl' \$INCLUDE directives.
  -w Generate WKS records for SMTP/TCP for every MX RRset
  -X Generate only the BIND conf/boot file(s) and exit
  -y [mode=[D|M]
     Set SOA serial numbers to use date/version format
     mode=D  Set day format of YYYYMMDDvv allowing 100 versions/day (default)
         =M  Set month format of YYYYMMvvvv allowing 10,000 versions/month
  -Z ADDRESS [ADDRESS]
     Specify ADDRESS of primary from which to load unsaved zone data
  -z ADDRESS [ADDRESS]
     Specify ADDRESS of primary from which to load saved zone data
  -show-single-ns [-hide-single-ns]
     Report subdomain delegations that only have a single name server if
     auditing is in effect (default)
  -show-dangling-cnames [-hide-dangling-cnames] [REMOTE-DOMAIN [REMOTE-DOMAIN]]
     Report CNAMEs that point to non-existent external domain names or
     domain names with no RRs if auditing is in effect (default)
  -show-chained-cnames [-hide-chained-cnames]
     Display each out-of-zone chained CNAME if auditing (default is -hide)
  -query-external-domains [-no-query-external-domains]
     Make DNS queries for domain names in zones external to -d DOMAIN (default)
  -debug[:directory] [-no-debug]
     Prevent removal of temp files in /tmp or [directory] (default is -no)
  -glue-level [LEVEL]
     Specify/display the number (0-$j) of chained inter-subzone delegations
     that are permitted before optional parent-zone glue RRs become mandatory
     if auditing is in effect.  Default LEVEL is 1.

The zone verification options are:
  -f FILE
     Read command line options from FILE
  -v Display the version number of h2n
  -I [audit|audit-only]
     Control level and type of various RFC conformance checks
     audit       Check zone data integrity & report names with illegal chars.
     audit-only  Check zone data integrity & ignore names with illegal chars.
  -V DOMAIN [DOMAIN]
     Verify the integrity of a domain obtained by an AXFR query
  -recurse[:depth] [-no-recurse]
     Recursively verify delegated subdomains to level [depth] (default is -no)
  -show-single-ns [-hide-single-ns]
     Report subdomain delegations that only have a single name server (default)
  -show-dangling-cnames [-hide-dangling-cnames] [REMOTE-DOMAIN [REMOTE-DOMAIN]]
     Report CNAMEs that point to non-existent out-of-zone domain names or
     domain names with no RRs (default)
  -show-chained-cnames [-hide-chained-cnames]
     Display each out-of-zone chained CNAME (default is -hide)
  -query-external-domains [-no-query-external-domains]
     Issue DNS queries for domains in zones external to -V DOMAIN (default)
  -check-del [-no-check-del]
     Check delegation of all discovered NS RRs (default)
  -debug[:directory] [-no-debug]
     Prevent removal of temp files in /tmp or [directory] (default is -no)
     Zone data temp file is re-verified instead of making a new AXFR query.
  -glue-level [LEVEL]
     Specify/display the number (0-$j) of chained inter-subzone delegations
     that are permitted before optional parent-zone glue RRs become mandatory.
     Default LEVEL is 3.

This is $0 v$VERSION
EOT
	    exit(0) unless defined wantarray;
	    $message_count++;

	}
	if (@option_args) {
	    #
	    # There should not be any leftover arguments
	    # after processing an `h2n' option.  If there
	    # are, report them and move on.
	    #
	    $option_args_txt = join(" ", @option_args);
	    $tmp1 = (scalar(@option_args) == 1) ?? " was" !! "s were";
	    print STDERR "Warning: the following argument${tmp1} leftover ",
			 "after processing the\n",
			 "         `$original_option' option: $option_args_txt",
			 "\n";
	}
    }	# end of option-processing `while' statement

    $net = keys(%Net_Ranges);
    if ($Verify_Mode) {
	if ($net || $Domain || defined($User)) {
	    print STDERR "The -d, -n/-a, and/or -u options ",
			 "are incompatible with -V.\n";
	    GIVE_UP() unless defined wantarray;
	    $message_count++;
	}
    } elsif (!$Do_CNAME && $Multi_Homed_Mode ~~ /[CP]/) {
	print STDERR "`+m $Multi_Homed_Mode' option ",
		     "incompatible with -A option.\n";
	GIVE_UP() unless defined wantarray;
	$message_count++;
    } elsif (!defined(wantarray) && (!$net || !$Domain || !defined($User))) {
	print STDERR "Must specify at least -d, one -n/-a, and -u.\n";
	GIVE_UP();
    } else {
        $Boot_Dir   = $cwd unless defined($Boot_Dir);
        $DB_Dir     = $cwd unless defined($DB_Dir);
	$Search_Dir = $DB_Dir unless defined($Search_Dir);
	if ($Search_Dir eq $cwd) {
	    $Search_Display_Dir = ".";
	} else {
	    $Search_Display_Dir = $Search_Dir;
	}
	unless (defined($Special_File)) {
	    ($Special_File = $Domain) ~~ s/[.].*//;
	    $Special_File = "spcl.$Special_File";
	}
	$error = 0;
	foreach $tmp (@alt_spcl_files) {
	    ($file = $tmp) ~~ s/.*spcl=//;
	    unless (-f "$Search_Dir/$file" && -r _) {
		print STDERR "\n" if $error == 1;
		print STDERR "Improper `spcl=' argument in option `$tmp'.\n",
			     "The specified file is non-existent, invalid, ",
			     "or has no read access in the\n",
			     "`$Search_Dir' directory.\n";
		$error = 1;
	    }
	}
	if ($error) {
	    GIVE_UP() unless defined wantarray;
	    $message_count++;
	}
	if ($Conf_Prefile) {
	    #
	    # Make sure that any file to be prepended (+C option)
	    # to the BIND 8/9 configuration file (+c option) can
	    # be found in the following search path:
	    #
	    #   1. $Boot_Dir  [-B option]
	    #   2. getcwd()   [current directory]
	    #
	    # The -B option is the preferred method for the sake of logical
	    # consistency but the CWD is also searched for backwards
	    # compatibility with the way that the GEN_BOOT() subroutine
	    # searches for the following files:
	    #
	    #   spcl-conf  spcl-conf.sec  spcl-conf.sec.save
	    #
	    # that, if found,  are appended to the BIND 8/9 configuration files.
	    #
	    $file = "";
	    foreach $data ($Boot_Dir, $cwd) {
		next unless -e "$data/$Conf_Prefile";
		$file = "$data/$Conf_Prefile";
		last;
	    }
	    unless ($file && -f $file && -r _) {
		print STDERR "Improper +C option ($Conf_Prefile).\nThe ",
			     "specified file is non-existent, invalid, ",
			     "or has no read access in the\n";
		$data = "`$cwd' directory.";
		$data = "`$Boot_Dir' or " . $data if $Boot_Dir ne $cwd;
		print STDERR "$data\n";
		GIVE_UP() unless defined wantarray;
		$message_count++;
	    } else {
		$Conf_Prefile = $file;
	    }
	}
	if (@c_Opt_Patterns) {
	    $argument = 0;
	    foreach $tmp (@c_Opt_Patterns) {
		$domain_arg = $c_Opt_Pat_Rel{$tmp};
		$argument = 1 if lc($domain_arg) eq lc($Domain);
		if ($argument) {
		    ($message = <<"EOT") ~~ s/^\s+\|//gm;
	    |The `$domain_arg' domain name argument is ambiguously
	    |specified.  Its appearance in the -d option is incompatible
	    |with a simultaneous specification in the -c option.
EOT
		    print STDERR "$message";
		    GIVE_UP() unless defined wantarray;
		    $message_count++;
		    last;
		}
	    }
	}
	if (@e_Opt_Patterns) {
	    $argument = "";
	    foreach $tmp (@e_Opt_Patterns) {
		($domain_arg = $tmp) ~~ s/\\[.]/./g;
		if ($domain_arg eq lc($Domain)) {
		    $argument = "-d option";
		} else {
		    if (exists($c_Opt_Pat_Rel{$tmp})) {
			$argument = "-c option";
		    }
		    if (exists($PTR_Pat_Rel{$tmp})) {
			if ($argument) {
			    $argument = "-c and -p options";
			} else {
			    $argument = "-p option";
			}
		    }
		}
		if ($argument) {
		    ($message = <<"EOT") ~~ s/^\s+\|//gm;
	    |The `$domain_arg' domain name argument is ambiguously
	    |specified.  Its appearance in a -e option is incompatible
	    |with a simultaneous specification in the $argument.
EOT
		    print STDERR "$message";
		    GIVE_UP() unless defined wantarray;
		    $message_count++;
		    last;
		}
	    }
	}
	if (@p_Opt_Patterns) {
	    $message = "";
	    foreach $tmp (@p_Opt_Patterns) {
		$domain_arg = $PTR_Pat_Rel{$tmp};
		if (lc($domain_arg) eq lc($Domain)) {
		    ($message = <<"EOT") ~~ s/^\s+\|//gm;
	    |The `$domain_arg' domain name argument is ambiguously
	    |specified.  Its appearance in the -d option is incompatible
	    |with a simultaneous specification in the -p option.
EOT
		} elsif (exists($c_Opt_Pat_Rel{$tmp}) &&
			 $c_Opt_Spec{$tmp}{MODE} ~~ /I/) {
		    ($message = <<"EOT") ~~ s/^\s+\|//gm;
	    |Improper `-p $domain_arg' option; the domain name
	    |matches that of a -c option which has been flagged with `mode=I'
	    |to indicate that it is an intra-zone subdomain of the -d option.
	    |The -p option is restricted to domains that are in a different
	    |DNS zone than the -d option ($Domain).
EOT
		}
		if ($message) {
		    print STDERR "$message";
		    GIVE_UP() unless defined wantarray;
		    $message_count++;
		    last;
		}
	    }
	}
	if (!defined(wantarray) && $Preserve_Case) {
	    #
	    # Use the CPAN module `Tie::CPHash' (already loaded when
	    # the -P option was processed) to enhance the following
	    # global hashes so that their keys can be matched in a
	    # case-insensitive manner while still preserving the case
	    # of the last-stored key as returned by the each() and
	    # keys() functions.
	    # NOTE: This added functionality comes at the expense of a fair
	    #       amount of overhead according to the module's documentation.
	    #       Thus, only the necessary hashes are specified.
	    #
	    tie %Aliases,       "Tie::CPHash";
	    tie %Comments,      "Tie::CPHash";
	    tie %Hosts,	        "Tie::CPHash";
	    tie %c_Opt_Aliases, "Tie::CPHash";
	    tie %Deferred_PTR,  "Tie::CPHash";
	    tie %Pending_PTR,   "Tie::CPHash";
	    tie %RRowners,      "Tie::CPHash";
	    tie %Wildcards,     "Tie::CPHash";
	}
    }
    return $message_count;
}


# Validate an IPv4 network specification passed in one of the following formats:
#
#   (network, CIDRsize,    netmask="")
#   (network, CIDRsize="", netmask)
#   (undef,   CIDRsize,    netmask="")
#   (undef,   CIDRsize="", netmask)
#
# where network matches a format of x[.x[.x[.x]]]
#       CIDRsize is an integer from 1 to 32
#       netmask matches the format of x.x.x.x
#
# * A valid `network/CIDRsize' specification returns the corresponding netmask
#   and normalizes the network to its minimum number of octets.
# * A valid `network:netmask' specification returns the corresponding CIDR
#   size and normalizes the network to its minimum number of octets.
# * A valid `CIDRsize' specification returns the corresponding netmask.
# * A valid `netmask' specification returns the corresponding CIDRsize.
#
# NOTE: Parameters *must* be passed using the following convention:
#
#       Input variables - passed by *reference* and subject to change
#       Output variable - initialized to "" and passed by *reference*
#       Void parameter  - the undefined value passed as a placeholder
#
# Returns: the undefined value or null string if no error
#          an error string otherwise
#
#
#############################################################################
#
#                        NETWORKING TERMINOLOGY
#                        ======================
#
#                   Determining the Class of an Address
#                   -----------------------------------
#
#    Given a 32-bit address, xxxxxxxx.xxxxxxxx.xxxxxxxx.xxxxxxxx,
#
#    0xxxxxxx.xxxxxxxx.xxxxxxxx.xxxxxxxx  Class A  1-127.x.x.x
#    10xxxxxx.xxxxxxxx.xxxxxxxx.xxxxxxxx  Class B  128-191.x.x.x
#    110xxxxx.xxxxxxxx.xxxxxxxx.xxxxxxxx  Class C  192-223.x.x.x
#    1110xxxx.xxxxxxxx.xxxxxxxx.xxxxxxxx  Class D  224-239.x.x.x (multicast)
#    1111xxxx.xxxxxxxx.xxxxxxxx.xxxxxxxx  Class E  240-255.x.x.x (experimental)
#
#    The original concept of network classes has given way to a
#    more efficient way of allocating networks of IP addresses
#    called Classless InterDomain Routing or CIDR.
#
#
#                       CIDR Conversion Table
#                       ---------------------
#
#       CIDR
#      Length        Mask         # Networks    # Addresses
#      ------   ---------------   ----------   -------------
#        /0     0.0.0.0           special wildcard mask used in ACLs
#                                 to match any address to [0.0.0.0]
#        /1     128.0.0.0           128 A      2,147,483,648
#        /2     192.0.0.0            64 A      1,073,741,824
#        /3     224.0.0.0            32 A        536,870,912
#        /4     240.0.0.0            16 A        268,435,456
#        /5     248.0.0.0             8 A        134,217,728
#        /6     252.0.0.0             4 A         67,108,864
#        /7     254.0.0.0             2 A         33,554,432
#        /8     255.0.0.0             1 A         16,777,216
#        /9     255.128.0.0         128 B          8,388,608
#        /10    255.192.0.0          64 B          4,194,304
#        /11    255.224.0.0          32 B          2,097,152
#        /12    255.240.0.0          16 B          1,048,576
#        /13    255.248.0.0           8 B            524,288
#        /14    255.252.0.0           4 B            262,144
#        /15    255.254.0.0           2 B            131,072
#        /16    255.255.0.0           1 B             65,536
#        /17    255.255.128.0       128 C             32,768
#        /18    255.255.192.0        64 C             16,384
#        /19    255.255.224.0        32 C              8,192
#        /20    255.255.240.0        16 C              4,096
#        /21    255.255.248.0         8 C              2,048
#        /22    255.255.252.0         4 C              1,024
#        /23    255.255.254.0         2 C                512
#        /24    255.255.255.0         1 C                256
#        /25    255.255.255.128    2 subnets             128
#        /26    255.255.255.192    4 subnets              64
#        /27    255.255.255.224    8 subnets              32
#        /28    255.255.255.240   16 subnets              16
#        /29    255.255.255.248   32 subnets               8
#        /30    255.255.255.252   64 subnets               4
#        /31    255.255.255.254       none                 2
#        /32    255.255.255.255     1/256 C                1
#
#
#
#                      RFC-1918 Reserved Network Numbers
#                      ---------------------------------
#
#  The following networks are reserved for use by entities which do not
#  require globally unique address space.  The obvious advantage for the
#  Internet at large is the conservation of globally unique address space
#  by not using it where global uniqueness is not required.
#
#  Class    Start         End          # Addrs              Comment
#  ----- ----------- --------------- ----------  -------------------------------
#    A   10.0.0.0    10.255.255.255  16,777,216    a single Class A network
#    B   172.16.0.0  172.31.255.255   1,048,576   16 contiguous Class B networks
#    C   192.168.0.0 192.168.255.255     65,536  256 contiguous Class C networks
#
#
sub CHECK_NET {
    my ($network_ref, $cidr_ref, $mask_ref) = @_;
    my ($adverb, $binary_mask, $bit_num, $cidr, $error, $factor, $mask);
    my ($network, $num_octets, $octet, $octet_1, $octet_2, $octet_3, $octet_4);
    my ($octet_count, $rightmost_octet);
    my $IPv4_pattern =
		'^(?:(25[0-5]|(?:2[0-4]|1[0-9]|[1-9]?)[0-9])(?:[.](?=.)|\z))';

    $error = "";

    if (defined($network_ref)) {
	$network = ${$network_ref};
	if ($network !~ /$IPv4_pattern{1,4}$/) {
	    $error = " Invalid network specification.\n";
	} else {
	    ($octet_1, $octet_2,
	     $octet_3, $octet_4) = split(/[.]/, $network, 4);
	    if (defined($octet_4)) {
		$num_octets = 4;
	    } elsif (defined($octet_3)) {
		$num_octets = 3;
	    } elsif (defined($octet_2)) {
		$num_octets = 2;
	    } else {
		$num_octets = 1;
	    }
	}
    }
    $cidr = ${$cidr_ref};
    $mask = ${$mask_ref};
    if (defined($cidr)) {
	unless ($cidr ~~ /^\d+$/) {
	    $error .= " Invalid CIDR specification.\n";
	} elsif ($cidr < 1 || $cidr > 32) {
	    $error .= " Invalid CIDR size (must be 1 to 32).\n";
	}
    } elsif (!defined($mask) || $mask !~ /$IPv4_pattern{4}$/) {
	$error .= " Invalid netmask specification.\n";
    } else {
	#
	# Prepare a 32-bit integer version of the netmask
	# and do a bit-wise inspection from right to left.
	# Once a "1" is found, make sure that there are no
	# intervening "0"s between that point and the leftmost bit.
	#
	$binary_mask = unpack("N", pack("C4", split(/[.]/, $mask)));
	$cidr = 0;
	foreach $bit_num (reverse 1..32) {
	    if ($binary_mask & 0x00000001) {
		$cidr = $bit_num unless $cidr;
	    } elsif ($cidr) {
		$error .= " Invalid netmask specification"
		       .  " (non-contiguous).\n";
		last;
	    }
	    $binary_mask >>= 1;
	}
	if ($cidr == 0) {
	    $error .= " Invalid netmask specification (all zeros).\n";
	}
    }
    return $error if $error;
    if (defined($cidr_ref) && !${$cidr_ref}) {
	#
	# Pass back the computed CIDR size from the netmask that was passed in.
	#
	${$cidr_ref} = $cidr;
    }
    if (defined($mask_ref) && !${$mask_ref}) {
	#
	# Pass back the computed netmask from the CIDR size that was passed in.
	#
	${$mask_ref} = sprintf("%u.%u.%u.%u",
			       unpack("C4", pack("B32", '1' x $cidr)));
    }
    return if !defined($network_ref);

    # So far, each of the passed parameters is syntactically valid.
    # If a network specification was passed, we also have a valid CIDR
    # size which was passed directly or computed from a passed netmask.
    # Now it's time to check if the network/CIDR combination is logically
    # valid.  We'll start by checking for some very general formatting errors.

    if ($cidr <= 8) {
	if (($num_octets >= 2 && $octet_2 != 0) ||
	    ($num_octets >= 3 && $octet_3 != 0) ||
	    ($num_octets == 4 && $octet_4 != 0)) {
	    $error = " CIDR sizes /1-8 require just the first"
		   . " non-zero network octet to be specified.\n"
		   . " If other octets are included, they must be zeros.\n";
	} else {
	    $network = $rightmost_octet = $octet_1;
	    $octet = "first";
	}

    } elsif ($cidr <= 16) {
	if ($num_octets < 2) {
	    $adverb = "";
	} elsif (($num_octets >= 3 && $octet_3 != 0) ||
		 ($num_octets == 4 && $octet_4 != 0)) {
	    $adverb = "just ";
	}
	if (defined($adverb)) {
	    $error = " CIDR sizes /9-16 require ${adverb}the first"
		   . " two network octets to be specified.\n";
	    if ($adverb) {
		$error .= " If other octets are included,"
		       .  " they must be zeros.\n";
	    }
	} else {
	    $network = "$octet_1.$octet_2";
	    $rightmost_octet = $octet_2;
	    $octet = "second";
	}

    } elsif ($cidr <= 24) {
	if ($num_octets < 3) {
	    $adverb = "";
	} elsif ($num_octets == 4 && $octet_4 != 0) {
	    $adverb = "just ";
	}
	if (defined($adverb)) {
	    $error = " CIDR sizes /17-24 require ${adverb}the first"
		   . " three network octets to be specified.\n";
	    if ($adverb) {
		$error .= " If the fourth octet is included,"
		       .  " it must be zero.\n";
	    }
	} else {
	    $network = "$octet_1.$octet_2.$octet_3";
	    $rightmost_octet = $octet_3;
	    $octet = "third";
	}

    } elsif ($cidr <= 32) {
	if ($num_octets < 4) {
	    $error = " CIDR sizes /25-32 require all four"
		   . " network octets to be specified.\n";
	} else {
	    $rightmost_octet = $octet_4;
	    $octet = "fourth";
	}
    }
    return $error if $error;

    # Finally, if the CIDR size is not 8, 16, 24, or 32, the rightmost
    # non-zero octet of a passed network specification must be evenly
    # divisible by the appropriate power of two.  Make sure this is so.
    #

    $factor = $cidr % 8;
    if ($factor) {
	$factor = 256 >> $factor;	# right-shift by the needed bits
	#
	# For a remainder of   1,  2,  3,  4, 5, 6, or 7
	#       "$factor" is 128, 64, 32, 16, 8, 4, or 2
	#
	if ($rightmost_octet % $factor) {
	    $error  = " Invalid network specification for"
		    . " CIDR size of /$cidr";
	    $error .= (${$mask_ref}) ?? " (from subnetmask).\n" !! ".\n";
	    $error .= " The $octet octet must be a multiple of $factor.\n";
	    return $error;
	}
    }
    ${$network_ref} = $network;
    return;
}



# Validate an IPv6 network specification passed in one of the following formats:
#
#   (network, CIDRsize,    netmask="")
#   (network, CIDRsize="", netmask)
#   (undef,   CIDRsize,    netmask="")
#   (undef,   CIDRsize="", netmask)
#
# where network matches a format of a valid IPv6 prefix
#       CIDRsize is an integer from 1 to 128
#       netmask matches the format of a valid IPv6 network mask
#
# * A valid `network/CIDRsize' specification returns the corresponding netmask
#   and normalizes the network to its compressed format.
# * A valid `network:netmask' specification returns the corresponding CIDR
#   size and normalizes the network to its compressed format.
# * A valid `CIDRsize' specification returns the corresponding netmask.
# * A valid `netmask' specification returns the corresponding CIDRsize.
#
# NOTE: Parameters *must* be passed using the following convention:
#
#       Input variables - passed by *reference* and subject to change
#       Output variable - initialized to "" and passed by *reference*
#       Void parameter  - the undefined value passed as a placeholder
#
# Returns: the undefined value or null string if no error
#          an error string otherwise
#

sub CHECK_NET6 {
    my ($network_ref, $cidr_ref, $mask_ref) = @_;
    my ($binary_mask, $binary_net, $cidr, $error, $mask, $network);
    my (@int_fields);

    $error = "";

    if (defined($network_ref)) {
	$network = ${$network_ref};
	if ($network !~ /$IPv6_pattern/oi) {
	    $error = " Invalid network specification.\n";
	}
    }
    $cidr = ${$cidr_ref};
    $mask = ${$mask_ref};
    if (defined($cidr)) {
	if ($cidr !~ /^\d+$/) {
	    $error .= " Invalid CIDR specification.\n";
	} elsif ($cidr < 1 || $cidr > 128) {
	    $error .= " Invalid CIDR size (must be 1 to 128).\n";
	}
    } elsif (!defined($mask) || $mask !~ /$IPv6_pattern/oi) {
	$error .= " Invalid netmask specification.\n";
    } else {
	#
	my ($bit_num, $i, $tmp);

	# Create an eight-element integer array which holds the
	# decimal representation of each 16-bit field of the netmask
	# and then repack the array to four 32-bit integers.  This
	# is to keep things 32-bit compatible and in lieu of requiring
	# a CPAN module dealing with IP address operations.
	#
	@int_fields = map(hex, split(/:/, EXPAND_IPv6($mask, 'PARTIAL')));
	@int_fields = unpack("N4", pack("n8", @int_fields));

	# Start inspecting the 128-bit mask from right to left
	# in four 32-bit chunks.  Once a "1" is found, make sure
	# that there are no intervening "0"s between that point
	# and the leftmost bit.  The algorithm relies on one of
	# the bit shift operators (">>") which only work on integers.
	# A single bit string can not be shifted with "<<" or ">>".
	#
	$cidr = 0;
	$i = 3;
	while (!$error && $i >= 0) {
	    $tmp = $int_fields[$i];
	    foreach $bit_num (reverse 1..32) {
		if ($tmp & 0x00000001) {
		    $cidr = $bit_num + ($i * 32) unless $cidr;
		} elsif ($cidr) {
		    $error .= " Invalid netmask specification"
			   .  " (non-contiguous).\n";
		    last;
		}
		$tmp >>= 1;
	    }
	    $i--;
	}
	unless ($cidr) {
	    $error .= " Invalid netmask specification (all zeros).\n";
	}
    }
    return $error if $error;
    if (defined($cidr_ref) && !${$cidr_ref}) {
	#
	# Pass back the computed CIDR size from the netmask that was passed in.
	#
	${$cidr_ref} = $cidr;
    }
    if (defined($mask_ref) && !${$mask_ref}) {
	#
	# Pass back the computed netmask from the CIDR size that was passed in.
	#
	${$mask_ref} = COMPRESS_IPv6(sprintf("%x:%x:%x:%x:%x:%x:%x:%x",
					     unpack("n8", pack("B128",
							       '1' x $cidr))));
    }
    return if !defined($network_ref);

    # So far, each of the passed parameters is syntactically valid.
    # If a network specification was passed, we also have a valid CIDR
    # size which was passed directly or computed from a passed netmask.
    # Now check if the network/CIDR combination is logically valid.

    # Create 128-bit packed strings that are the
    # binary representations of the network and mask.
    #
    @int_fields = map(hex, split(/:/, EXPAND_IPv6($network, 'PARTIAL')));
    $binary_net  = pack("n8", @int_fields);
    $binary_mask = pack("B128", '1' x $cidr);
    if (($binary_net & $binary_mask) eq $binary_net) {
	$network = COMPRESS_IPv6($network);
    } else {

	my ($factor, $offset);

	$network = EXPAND_IPv6($network, 'FULL');
	$offset  = int(($cidr - 1) / 4) + int(($cidr - 1) / 16);
	$error   = " The network prefix has more bits than the CIDR size:\n"
		 . "   $network\n"
		 . "   "  .  " " x $offset  .  "^\n"
		 . " This is the rightmost non-zero hex digit for a /$cidr"
		 . " prefix";
	$factor = $cidr % 4;
	if ($factor) {
	    $factor = 16 >> $factor; # right-shift the proper number of bits
	    #
	    # For a remainder of 1, 2, or 3
	    #       "$factor" is 8, 4, or 2
	    #
	    $error .= ";\n the digit must also be a multiple of $factor.\n";
	} else {
	    $error .= ".\n";
	}
	return $error;
    }
    return;
}



#
# For CIDR sizes /8 to /24, calculate all of the constituent
# class A, B, or C subnets for a given network and return
# them to the caller as a list.
#
# For CIDR sizes /25 to /32, calculate the range of addresses
# for use in the default naming scheme of the sub-class-C DB file.
# Unless overridden by a `-n x.x.x.x  domain=zone-name' option,
# the default zone file name will also serve as the basis for the
# zone name itself.
#
sub SUBNETS {
    my ($network, $cidr_size) = @_;
    my ($additional_units, $base_net, $final_value, $last_octet, @subnets);

    if ($cidr_size <= 24) {
	push(@subnets, $network);	# the network itself is always first
	return @subnets unless $cidr_size % 8;
	$base_net = $last_octet = $network;
	$base_net ~~ s/[.]\d+$//;
	$last_octet ~~ s/.+[.]//;
	if ($cidr_size < 16) {
	    $additional_units = (2 ** (16 - $cidr_size)) - 1;
	} else {
	    $additional_units = (2 ** (24 - $cidr_size)) - 1;
	}
	for (1 .. $additional_units) {
	    $last_octet++;
	    push(@subnets, "$base_net.$last_octet");
	}
    } else {
	#
	# For CIDR sizes 25 to 32, a single array element will
	# be returned in the following format:
	#
	#   class-C_subnet:first_host_address-last_host_address
	#     ^^^^^^^^^^      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
	#     lookup key      host address or address range
	#
	# Examples:  192.6.19.0/25     => 192.6.19:0-127
	#                                 db.192.6.19.0-127
	#            156.153.254.80/28 => 156.153.254:80-95
	#                                 db.156.153.254.80-95
	#
	# For a CIDR size of 32, the address range is simply
	# replaced by the host address number itself, e.g.,
	#
	#            192.6.19.97/32    => 192.6.19:97
	#                                 db.192.6.19.97
	#
	$base_net = $last_octet = $network;
	$base_net ~~ s/[.]\d+$//;
	$last_octet ~~ s/.+[.]//;
	if ($cidr_size == 32) {
	    push(@subnets, "$base_net:$last_octet");
	} else {
	    $additional_units = (2 ** (32 - $cidr_size)) - 1;
	    $final_value = $last_octet + $additional_units;
	    push(@subnets, "$base_net:$last_octet-$final_value");
	}
    }
    return @subnets;
}



#
# Subroutine for normalizing various data items once a complete
# view of the operating environment is obtained from PARSE_ARGS.
#
# Normal mode:
# ------------
# * Establish what we will be using for the SOA MNAME and RNAME
#   fields (-h/-u options) and the global MX RRset (-m option)
#   as well as the various NS RRsets (-s/-S options).
#   Single-label domain names will be qualified with the current
#   domain (-d option).
# * Validate any zone apex records submitted via the -T option.
#   NOTE: Error/warning messages will be generated for any invalid
#         domain name and/or SOA RR field.  A go/no-go decision for
#         proceeding will be made depending on the severity of the
#         problems and the error checking level set by the -I option.
# * Set the default mode for handling multi-homed hosts.
# * Optimize the search arrays for the -e, -c, and -p options to
#   accommodate super- and subdomains of related domain trees.
# * Try to query the MNAME host to see what version of BIND is running
#   so that our RFC-2308 status can be unequivocally set.  This also
#   helps to determine whether symbolic TTL values can be used.
#
# Normal mode and Verify mode:
# ---------------------------
# * Get the version of DiG that is available.  This allows the `h2n'
#   program to make various parsing and buffer-size adjustments.
#
sub FIXUP {
    my ($action, $alias, $apex_rr_aliases, $cname_pat, $data, $domain_part);
    my ($epat, $error, $file, $fixup_def_action, $flag, $i, $j, $lc_alias);
    my ($major_version, $message, $minor_version, $mxhost, $patch_version);
    my ($preference, $rdata, $rrtype, $status, $s, $t, $tmp, $tmp_rfc_952);
    my ($tmp_rfc_1123, $tmp_verbose, $ttl, $user_part);
    my (%server_name, @sorted, @temp, @unique_servers, @unsorted);

    unless ($Verify_Mode) {
	$status = 0;
	$action = "";
	$tmp_rfc_952  = $RFC_952;
	$tmp_rfc_1123 = $RFC_1123;
	$RFC_952 = 0;
	$RFC_1123 = 1;		# SOA, NS, and MX RRs should be RFC-compliant
	$fixup_def_action = ($DefAction eq "Warning") ?? "Warning" !! "Error";
	$Domain ~~ s/[.]$//;
	#
	# Although the owner fields of SOA records, i.e., delegated domain
	# names, are not subject to RFC-1123 name checking, the fact that
	# this name will become part of the FQDN of A records generated
	# by this program means that the higher standard must be applied.
	#
	$error = CHECK_NAME($Domain, 'A');
	if ($error) {
	    $status = $error;
	    $action = ($error == 3) ?? "Error" !! $fixup_def_action;
	    print STDERR "$action: Domain name `$Domain' (-d) is invalid.\n";
	}

	if ($Host eq '.' || $Host eq '@') {
	    #
	    # Even though it is clear from the spirit of the RFCs that
	    # the SOA MNAME field should contain the zone's master
	    # name server, BIND does allow the root zone to appear as
	    # a placeholder.  Accommodate this possibility as an
	    # undocumented feature.  Also allow the "@" symbol which,
	    # in this context, represents the zone name of the -d option.
	    # Don't leave the special "@" symbol as-is, however, since
	    # its context will be incorrect in any reverse-mapping zones.
	    #
	    $RespHost = ($Host eq '@') ?? $Domain !! $Host;
	} else {
	    ($tmp = $Host) ~~ s/[.]$//;
	    $error = CHECK_NAME($tmp, 'A');
	    if ($error) {
		$status = $error if $error > $status;
		$action = ($error == 3) ?? "Error" !! $fixup_def_action;
		print STDERR "$action: SOA host name `$Host' (-h) ",
			     "is invalid.\n";
	    }
	    if ($Host ~~ /[.]/) {
		$RespHost = "$Host.";
	    } else {
		$RespHost = "$Host.$Domain.";
	    }
	    $RespHost ~~ s/[.][.]/./g;		# remove any redundant "."
	}

	# As of BIND 4.9.4, RNAMEs in SOA and RP can have any printable
	# character in the first label as long as the subsequent labels
	# form an RFC1123-compliant domain name.  Since this has not been
	# make official in any RFC subsequent to RFC-1035, the preference
	# of the `h2n' program is to stick with the original specification
	# of interpreting the first unescaped "." as the implied "@" character.
	#
	if ($User ~~ /@/) {
	    $User ~~ s/\\@/@/;			    # unescape the "@"
	    ($user_part, $domain_part) = split(/@/, $User, 2);
	    $user_part ~~ s/[.]/\\./g;		    # escape "." in username
	    1 while $user_part ~~ s/\\\\/\\/g;	    # remove redundancies
	    if ($domain_part ~~ /[.]/) {	    # multiple domain labels
		$domain_part .= ".";		    # append root domain
	    } else {
		$domain_part .= ".$Domain.";	    # append our domain name
	    }
	    $RespUser = "$user_part.$domain_part";  # join w/ unescaped "."
	} elsif ($User !~ /[.]$/) {		    # already RNAME if no
	    $user_part = $User;			    # "@" and trailing "."
	    $user_part ~~ s/[.]/\\./g;		    # escape "." in username
	    1 while $user_part ~~ s/\\\\/\\/g;	    # remove redundancies
	    $RespUser = "$user_part.$Domain.";	    # join w/ unescaped "."
	} else {
	    $RespUser = $User;
	}
	$RespUser ~~ s/[.][.]/./g;
	#
	# Final inspection.
	#
	if ($RespUser ne ".") {
	    $tmp = $RespUser;
	    $tmp ~~ s/(?:\\[.]|[^.])*[.]//;	# strip first label
	    $tmp ~~ s/[.]$//;			# strip last dot
	    unless ($tmp) {
		$status = 3;			# flag this as a fatal error
		print STDERR "Error: SOA RNAME field `$RespUser' (-u) ",
			     "is invalid.\n";
	    } else {
		$error = CHECK_NAME($tmp, 'A');
		if ($error) {
		    $status = $error if $error > $status;
		    $action = ($error == 3) ?? "Error" !! $fixup_def_action;
		    print STDERR "$action: SOA RNAME field `$RespUser' (-u) ",
				 "is invalid.\n";
		}
	    }
	}

	# Clean up name servers.
	#
	foreach $s (@Full_Servers) {
	    $s = $Domain if $s eq '@';
	    ($tmp = $s) ~~ s/[.]$//;
	    $error = ($s) ?? CHECK_NAME($tmp, 'A') !! 0;
	    if ($error) {
		$status = $error if $error > $status;
		$action = ($error == 3) ?? "Error" !! $fixup_def_action;
		print STDERR "$action: Name server name `$s' (-s) ",
			     "is invalid.\n";
	    }
	    $s .= ".$Domain" unless $s ~~ /[.]/;
	    $s .= "." unless $s ~~ /[.]$/;
	    if ($action ne "Error" && exists($server_name{lc($s)})) {
		print STDERR "Ignoring redundant name server (-s): $s\n";
	    } else {
		push(@unique_servers, $s);
		$server_name{lc($s)} = 1;
	    }
	}
	@Full_Servers = @unique_servers;

	foreach $t (keys %Partial_Servers) {
	    @temp = split(' ', $Partial_Servers{$t});
	    @unique_servers = ();
	    %server_name = ();
	    foreach $s (@temp) {
		$s = $Domain if $s eq '@';
		($tmp = $s) ~~ s/[.]$//;
		$error = ($s) ?? CHECK_NAME($tmp, 'A') !! 0;
		if ($error) {
		    $status = $error if $error > $status;
		    $action = ($error == 3) ?? "Error" !! $fixup_def_action;
		    print STDERR "$action: Name server name `$s' (-S) ",
				 "is invalid.\n";
		}
		$s .= ".$Domain" unless $s ~~ /[.]/;
		$s .= "." unless $s ~~ /[.]$/;
		if ($action ne "Error" && exists($server_name{lc($s)})) {
		    print STDERR "Ignoring redundant name server (-S): $s\n";
		} else {
		    push(@unique_servers, $s);
		    $server_name{lc($s)} = 1;
		}
	    }
	    $Partial_Servers{$t} = join(' ', @unique_servers);
	}

	unless ($Do_MX || $Do_Zone_Apex_MX) {
	    if (@MX) {
		print STDERR "Warning: The global MX record(s) specified with ",
			     "the -m option(s) will\n",
			     "         not be generated due to the -M option ",
			     "also being specified.\n";
	    }
	} elsif ($Do_Zone_Apex_MX && !@MX) {
	    print STDERR "Warning: The `-T mode=M' option is effectively ",
			 "cancelled due to the fact\n",
			 "         that no global MX records were specified ",
			 "with the -m option.\n";
	    $Do_Zone_Apex_MX = 0;
	} elsif (@MX) {
	    #
	    # Clean up MX hosts.
	    #
	    %server_name = ();
	    foreach $s (@MX) {
		($preference, $mxhost) = split(' ', $s, 2);
		$mxhost ~~ s/[.]$//;
		$data = ($mxhost eq '@') ?? $Domain !! $mxhost;
		$error = ($data) ?? CHECK_NAME($data, 'MX') !! 0;
		if ($error) {
		    $status = $error if $error > $status;
		    $action = ($error == 3) ?? "Error" !! $fixup_def_action;
		    print STDERR "$action: MX hostname `$mxhost' (-m) ",
				 "is invalid.\n";
		}
		if ($mxhost ~~ /$Domain_Pattern$/o) {
		    #
		    # Prevent unnecessary verbosity by keeping in-domain
		    # names in origin-relative format since the MX records
		    # will appear only in the forward-mapping file.
		    #
		    $mxhost ~~ s/$Domain_Pattern$//o;
		} else {
		    $mxhost .= "." if $mxhost ~~ /[.]/;
		}
		$s = "$preference $mxhost";
		$mxhost = ($mxhost eq '@') ?? lc("$Domain.") !! lc($mxhost);
		if (exists($server_name{$mxhost})) {
		    $server_name{$mxhost} .= " $preference";
		} else {
		    $server_name{$mxhost} = $preference;
		}
	    }
	    unless ($action eq "Error") {
		#
		# Now go through the hash of MX hosts.  Those that are
		# redundantly specified will have multiple preference
		# values.  Keep the most preferred entry, i.e., the
		# preference value that is numerically smallest.
		#
		scalar(keys(%server_name));
		while (($mxhost, $data) = each %server_name) {
		    next if $data ~~ /^\d+$/;
		    @temp = sort { $a <=> $b } split(' ', $data);
		    $server_name{$mxhost} = $temp[0];
		}
		@unique_servers = ();
		foreach $s (@MX) {
		    ($preference, $mxhost) = split(' ', $s, 2);
		    $mxhost = ($mxhost eq '@') ?? lc("$Domain.") !! lc($mxhost);
		    unless (exists($server_name{$mxhost})
			    && $preference == $server_name{$mxhost}) {
			print STDERR "Ignoring redundant MX host (-m): $s\n";
		    } else {
			push(@unique_servers, $s);
			delete($server_name{$mxhost});
		    }
		}
		@MX = @unique_servers;
	    }
	}

	# Validate and register any zone apex RRs or aliases that were
	# configured with the -T option.  This is done by writing the
	# RRs to a temporary array and submitting the data to READ_RRs().
	#
	$apex_rr_aliases = (keys(%Apex_RRs) || keys(%Apex_Aliases)) ?? 1 !! 0;
	if ($apex_rr_aliases || $Do_Zone_Apex_MX) {
	    if ($apex_rr_aliases) {
		if ($Verbose) {
		    print STDOUT "Checking zone apex RRs (-T option)...\n";
		}
		if ($Debug) {
		    $file = "$Debug_DIR/h2n-T_option_RRs";
		    unless (open(*APEXRRS, '>', $file)) {
			print STDERR "Couldn't create temporary file for ",
				     "validating RRs entered with the -T ",
				     "option.\nError: $!\n";
		        GIVE_UP();
		    }
		}
	    }
	    @temp = ();
	    push(@temp, "-T option");
	    if (keys(%Apex_RRs)) {
		foreach $rrtype (keys %Apex_RRs) {
		    foreach $data (@{ $Apex_RRs{$rrtype} }) {
			$rdata = $data;
			if ($rdata ~~ /\n$/) {
			    #
			    # A newline appended to the "$rdata" string is a
			    # data structure signal to indicate that this is
			    # a continuation line of a multi-line record.
			    #
			    $rdata ~~ s/\n$//;
			    if ($rdata ~~ /\n$/) {
				#
				# Besides this being a continuation line,
				# a second appended newline signifies that
				# the previous line ended with an open quote
				# in effect.  Therefore, the usual cosmetic
				# indentation must not be added in order to
				# maintain data integrity.
				#
				push(@temp, $rdata);
				print APEXRRS $rdata if $Debug
			    } else {
				$tmp = "\t\t\t$rdata\n";
				push(@temp, $tmp);
				print APEXRRS $tmp if $Debug;
			    }
			} else {
			    ($ttl, $rdata) = split(/,/, $rdata, 2);
			    $tmp = "\@\t$ttl\t$rrtype\t$rdata\n";
			    push(@temp, $tmp);
			    print APEXRRS $tmp if $Debug;
			}
		    }
		}
	    }
	    if (keys(%Apex_Aliases)) {
		#
		# Add any CNAMEs that were configured with the -T option.
		# These always point to the zone apex.
		#
		while (($lc_alias, $alias) = each %Apex_Aliases) {
		    ($alias, $ttl) = split(' ', $alias, 2);
		    if ($alias ~~ /$Domain_Pattern[.]$/o) {
			#
			# Prevent unnecessary verbosity by keeping in-domain
			# names in origin-relative format.
			#
			$alias ~~ s/$Domain_Pattern[.]$//o;
			$Apex_Aliases{$lc_alias} = "$alias $ttl";
		    }
		    $tmp = sprintf("%s%s\tCNAME\t\@\n", TAB($alias, 16), $ttl);
		    push(@temp, $tmp);
		    print APEXRRS $tmp if $Debug;
		}
	    }
	    if ($apex_rr_aliases) {
		close(*APEXRRS) if $Debug;
		$tmp_verbose = $Verbose;
		$Verbose = 1;
		$Newline_Printed = READ_RRs(\@temp, "$Domain.", "$Domain.",
					    "$Domain.", 0);
		$Verbose = $tmp_verbose;
		$status = $Load_Status if $Load_Status > $status;
	    }
	    if ($Do_Zone_Apex_MX &&
		(($status == 2 && $fixup_def_action eq "Warning")
		 || $status < 2)) {
		#
		# Add the global MX records from the -m option to any
		# that were additionally specified for the zone apex
		# and report any redundancies between the two sets.
		#
		foreach $s (@MX) {
		    ($preference, $mxhost) = split(' ', $s, 2);
		    $mxhost = ($mxhost eq '@') ?? lc("$Domain.") !! lc($mxhost);
		    if (exists($Apex_Route_RRs{MX})
			&& exists($Apex_Route_RRs{MX}{$mxhost})) {
			print STDERR "Redundant MX hostname; -T/-m options\n",
				     " @\tMX\t$s\n";
		    }
		    # Prepend "," as the placeholder for the default TTL.
		    #
		    push(@{ $Apex_RRs{MX} }, ",$s");
		}
	    }
	    if ($apex_rr_aliases) {
		print STDERR "\n" while $Newline_Printed--;
	    }
	}

	if ($status > 1) {
	    if (($status == 2 && $fixup_def_action eq "Error") || $status > 2) {
		&GIVE_UP;
	    } else {
		($message = <<"EOT") ~~ s/^\s+\|//gm;
    |Attention! Because `h2n' is running with an error-checking level of
    |           `$Check_Level' (-I option), it will go ahead and process the
    |           host table despite the above warning(s).  It is very important,
    |           however, to have fully-compliant SOA, NS, and MX records in
    |           order to prevent interoperability issues with other name servers
    |           and/or mail servers.  These naming irregularities should be
    |           fixed at the earliest opportunity.
EOT
		print STDERR "$message\n";
	    }
	}
	$RFC_952  = $tmp_rfc_952;
	$RFC_1123 = $tmp_rfc_1123;

	# If no +m option was specified, forward and reverse RRsets of
	# multi-homed hosts will be generated in the default manner.
	#
	$Multi_Homed_Mode = "D" unless $Multi_Homed_Mode;

	# Optimize the search arrays for the -c, -p, and -e options.
	#
	for $i (1..2) {
	    if ($i == 1) {
		@temp = @c_Opt_Patterns;
		$j = scalar(@c_Opt_Patterns);
	    } else {
		@temp = @p_Opt_Patterns;
	    }
	    next unless @temp;
	    #
	    # If a domain and one or more of its subdomains were specified
	    # in a -c or -p option, they should be ordered from the most
	    # specific subdomain to the least specific superdomain, e.g.,
	    # `fx.movie.edu' should be tried for a matching host file entry
	    # before `movie.edu'.  Reversing the domain name labels, sorting
	    # them in descending order, and reversing the labels back again
	    # will accomplish this task.
	    #
	    @unsorted = ();
	    foreach $tmp (@temp) {
		if ($Domain ~~ /[.]$tmp$/i) {
		    #
		    # The domain of a -c or -p option is a parent domain
		    # of that specified in the -d option.  Add a special
		    # flag to allow a host in the -d domain to override
		    # the -c or -p processing that would otherwise occur.
		    #
		    if ($i == 1) {
			$c_Opt_Spec{$tmp}{MODE} .= "O";
		    } else {
			$p_Opt_Mode_Spec{$tmp} .= "O";
		    }
		}
		if ($i == 1) {
		    #
		    # Remember the original order in which the -c options
		    # were specified so that CNAME creation collisions
		    # can be resolved according to the -c option's rank.
		    #
		    $c_Opt_Spec{$tmp}{RANK} = $j;
		    $j--;
		}
		($domain_part = $tmp) ~~ s/\\[.]/./g;
		push(@unsorted, join('.', reverse(split(/[.]/, $domain_part))));
	    }
	    @sorted = sort { $b cmp $a } @unsorted;
	    foreach $tmp (@sorted) {
		$tmp = join('.', reverse(split(/[.]/, $tmp)));
		$tmp ~~ s/[.]/\\./g;
	    }
	    if ($i == 1) {
		@c_Opt_Patterns = @sorted;
	    } else {
		@p_Opt_Patterns = @sorted;
	    }
	}
	if (@e_Opt_Patterns >= 2) {
	    #
	    # If a domain and one or more of its subdomains were specified
	    # in a -e option, the subdomains are effectively redundant,
	    # e.g., `movie.edu' matches everything that `fx.movie.edu'
	    # matches.  All such subdomains will now be removed.
	    #
	    @unsorted = ();
	    foreach $epat (@e_Opt_Patterns) {
		($domain_part = ".$epat") ~~ s/\\[.]/./g;
		push(@unsorted, join('.', reverse(split(/[.]/, $domain_part))));
	    }
	    @sorted = sort { $a cmp $b } @unsorted;  # ascending order this time
	    $i = 0;
	    until ($i >= $#sorted) {
		($domain_part = $sorted[$i]) ~~ s/[.]/\\./g;
		while ($i < $#sorted && $sorted[$i + 1] ~~ /^$domain_part/) {
		    #
		    # Remove the array element that holds the unnecessary
		    # subdomain or duplicate domain name.
		    #
		    splice(@sorted, ($i + 1), 1);
		}
		$i++;
	    }
	    if (@sorted < @e_Opt_Patterns) {
		foreach $epat (@sorted) {
		    $epat ~~ s/[.]$//;
		    $epat = join('.', reverse(split(/[.]/, $epat)));
		    $epat ~~ s/[.]/\\./g;
		}
		@e_Opt_Patterns = @sorted;
	    }
	}
	if (@e_Opt_Patterns) {
	    #
	    # Look for any -e domains that happen to be parent domains
	    # of those specified in the -d option or -c/-p options.
	    # Construct the appropriate exception domain patterns in
	    # the "%e_Opt_Pat_Exceptions" hash.
	    #
	    foreach $epat (@e_Opt_Patterns) {
		@unsorted = ();
		if ($Domain ~~ /[.]$epat$/i) {
		    push(@unsorted,
			 join('.', reverse(split(/[.]/, ".$Domain"))));
		}
		foreach $tmp (@c_Opt_Patterns) {
		    ($domain_part = ".$tmp") ~~ s/\\[.]/./g;
		    if ($domain_part ~~ /[.]$epat$/) {
			push(@unsorted,
			     join('.', reverse(split(/[.]/, $domain_part))));
		    }
		}
		foreach $tmp (@p_Opt_Patterns) {
		    ($domain_part = ".$tmp") ~~ s/\\[.]/./g;
		    if ($domain_part ~~ /[.]$epat$/) {
			push(@unsorted,
			     join('.', reverse(split(/[.]/, $domain_part))));
		    }
		}
		unless (@unsorted) {
		    $e_Opt_Pat_Exceptions{$epat} = '^$';
		} else {
		    #
		    # Just as was done previously when effectively redundant
		    # subdomains were removed from the -e option, compress
		    # the list of exception domains down to the minimum set
		    # of matching highest-level domains.
		    #
		    @sorted = sort { $a cmp $b } @unsorted;
		    $i = 0;
		    until ($i >= $#sorted) {
			($domain_part = $sorted[$i]) ~~ s/[.]/\\./g;
			while ($i < $#sorted
			       && $sorted[$i + 1] ~~ /^$domain_part/) {
			    splice(@sorted, ($i + 1), 1);
			}
			$i++;
		    }
		    $domain_part = "";
		    foreach $tmp (@sorted) {
			$tmp = "." . join('.', reverse(split(/[.]/, $tmp)));
			$tmp ~~ s/[.]/\\./g;
			$domain_part .= "|$tmp";
		    }
		    $domain_part ~~ s/^\|//;
		    $e_Opt_Pat_Exceptions{$epat} = $domain_part;
		}
	    }
	}
    }

    unless (defined($Glueless_Limit)) {
	$Glueless_Limit = ($Verify_Mode) ?? $Verify_Glueless_Limit
					 !! $DB_Glueless_Limit;
    }
    if ($Display_Glueless_Limit) {
	$data = "Limit of glueless delegations among subzones of the same "
	      . "parent is set to $Glueless_Limit.";
	print STDOUT "$data\n";
    }
    $Verify_Delegations = 0 unless $Query_External_Domains;
    unless (defined($Show_Dangling_CNAMEs)) {
	#
	# Set an appropriate default value.
	#
	if ($Verify_Mode && $V_Opt_Domains[0] ~~ /[.]in-addr[.]arpa[.]$/) {
	    $Show_Dangling_CNAMEs = 0;
	} elsif ($Audit) {
	    $Show_Dangling_CNAMEs = 1;
	} else {
	    $Show_Dangling_CNAMEs = 0;
	}
    }
    if (scalar(keys(%Dangling_CNAME_Domains))) {
	#
	# One or more domains were specified in the following options
	# for controlling the display of dangling CNAMEs that are
	# encountered when a zone is audited:
	#
	#   -show-dangling-cnames [DOMAIN-to-display] [DOMAIN-to-display]
	#   -hide-dangling-cnames [DOMAIN-to-ignore]  [DOMAIN-to-ignore]
	#
	# First, separate the "show/hide" domains and eliminate redundancies.
	#
	@Dangling_CNAME_Domains = ();
	for $i (0..1) {
	    @temp = ();
	    foreach $cname_pat (keys(%Dangling_CNAME_Domains)) {
		$flag = $Dangling_CNAME_Domains{$cname_pat};
		if ($i == 0 && exists($c_Opt_Spec{$cname_pat})
			    && $c_Opt_Spec{$cname_pat}{MODE} ~~ /I/) {
		    if ($flag == 1) {
			#
			# Issue a warning if "-show" is cancelled.  Stay silent
			# about "-hide" since it represents the cancellation of
			# an option that's effectively redundant.
			#
			($tmp = $cname_pat) ~~ s/\\[.]/./g;
			print STDERR "Warning: The `-show-dangling-cnames ",
				     "$tmp'\n         option is being ",
				     "cancelled due to the fact that this ",
				     "domain name\n         was also ",
				     "specified as a -c option with mode=I ",
				     "(intra-zone subdomain).\n";
		    }
		    next;
		}
		if ($flag == $i) {
		    #
		    # Before processing the domain, see if the global
		    # "$Show_Dangling_CNAMEs" flag is set in the same
		    # context (show or hide).  If so, let the global
		    # flag effectively cancel the individual domain
		    # specification(s).
		    #
		    next if $Show_Dangling_CNAMEs == $flag;
		    push(@temp, $cname_pat);
		}
	    }
	    if (@temp >= 2) {
		#
		# If a domain and one or more of its subdomains were specified
		# in a "[show|hide]-dangling-cnames" option, the subdomains are
		# effectively redundant, e.g., `movie.edu' matches everything
		# that `fx.movie.edu' matches.  All such subdomains will now be
		# removed.
		#
		@unsorted = ();
		foreach $cname_pat (@temp) {
		    ($domain_part = ".$cname_pat") ~~ s/\\[.]/./g;
		    push(@unsorted,
			 join('.', reverse(split(/[.]/, $domain_part))));
		}
		@sorted = sort { $a cmp $b } @unsorted;  # ascending order
		$j = 0;
		until ($j >= $#sorted) {
		    ($domain_part = $sorted[$j]) ~~ s/[.]/\\./g;
		    while ($j < $#sorted
			   && $sorted[$j + 1] ~~ /^$domain_part/) {
			#
			# Remove the array element that holds the unnecessary
			# subdomain or duplicate domain name.
			#
			splice(@sorted, ($j + 1), 1);
		    }
		    $j++;
		}
		if (@sorted < @temp) {
		    foreach $cname_pat (@sorted) {
			$cname_pat ~~ s/[.]$//;
			$cname_pat = join('.',
					  reverse(split(/[.]/, $cname_pat)));
			$cname_pat ~~ s/[.]/\\./g;
		    }
		    @temp = @sorted;
		}
	    }
	    push(@Dangling_CNAME_Domains, @temp);# append the [compressed] array
	}
	#
	# Finally, sort the combined "show/hide" domains in descending
	# order from the most specific subdomain to the least specific
	# superdomain, e.g., `fx.movie.edu' should be tried for a matching
	# domain before `movie.edu'.
	#
	@unsorted = ();
	foreach $tmp (@Dangling_CNAME_Domains) {
	    ($domain_part = $tmp) ~~ s/\\[.]/./g;
	    push(@unsorted, join('.', reverse(split(/[.]/, $domain_part))));
	}
	@sorted = sort { $b cmp $a } @unsorted;
	foreach $tmp (@sorted) {
	    $tmp = join('.', reverse(split(/[.]/, $tmp)));
	    $tmp ~~ s/[.]/\\./g;
	}
	@Dangling_CNAME_Domains = @sorted;
    }

    # `h2n' will try to call the DiG utility to provide various
    # items of useful DNS information.  Get the version of DiG that
    # is installed on this system in order to accommodate the various
    # differences in which its output may appear.
    #
    $DiG_Version_Num = 0;
    if (open(*DIGOUT, '-|', "$DiG 1.0.0.127.in-addr.arpa. PTR 2>&1")) {
	while (<DIGOUT>) {
	    next unless /^; <<>> DiG (\d+)(?:[.](\d+))?(?:[.](\d+).*)? <<>>/;
	    $major_version = (defined $1) ?? $1 !! 0;
	    $minor_version = (defined $2) ?? $2 !! 0;
	    $patch_version = (defined $3) ?? $3 !! 0;
	    $DiG_Version_Num = (10000 * $major_version)
			       + (100 * $minor_version) + $patch_version;
	    last;
	}
	close(*DIGOUT);

	$DiG_Timeout = "time=$DiG_Timeout";
	if ($DiG_Version_Num < 80300) {
	    #
	    # Set the threshold at which long command lines to DiG
	    # must be split across two lines when following chained
	    # CNAMEs in the AUDIT_RRs subroutine.
	    #
	    $DiG_Bufsize = 98;
	    $DiG_Retries = "retry=$DiG_Retries";
	} elsif ($DiG_Version_Num < 90000) {
	    #
	    # The buffer size was increased in version 8.3.  Assume
	    # that the same value exists for subsequent 8.X versions.
	    #
	    $DiG_Bufsize = 382;
	    $DiG_Retries = "retry=$DiG_Retries";
	} else {
	    #
	    # Version 9 of DiG is a rewrite of this utility with a
	    # significant increase in the buffer sizes.
	    #
	    $DiG_Bufsize = 986;
	    $DiG_Retries = "tries=$DiG_Retries";
	}
    }

    unless ($Verify_Mode) {
	#
	# RFC-2308 is implemented in BIND name servers starting with
	# version 8.2.  This specifies that the SOA Minimum Field
	# is defined to be the negative caching interval and the
	# default time-to-live value is now defined with a new
	# master zone file directive, $TTL.
	# BIND version 8.2 and later will issue a warning when the
	# $TTL directive is missing from a master zone that is being
	# loaded.  BIND 9 versions prior to 9.2.0a1 will fail to load
	# master zones which are missing the $TTL directive.
	#
	# In order to suppress these warnings/errors, we'll try to
	# use DiG to issue a special query to the master name server
	# to find out which version of BIND it is running.
	# Knowing the BIND version allows an unambiguous determination
	# of our RFC-2308 status according to the following hierarchy:
	#
	#   (1) BIND version
	#          |
	#          |  overrides
	#          |
	#   (2) confirmed RFC-2308 status via a +t option
	#          OR
	#       discovered $TTL directives in existing DB files
	#          |
	#          |  overrides
	#          |
	#   (3) negated RFC-2308 status via a -o option with
	#       exactly four positional arguments
	#          |
	#          |  overrides
	#          |
	#   (4) default RFC-2308 status of "true" for `h2n'
	#       version 2.40 and later
	#          |
	#          |  obsoletes
	#          |
	#   (5) default RFC-2308 status of "false" for `h2n'
	#       version 2.39 and earlier.
	#
	# Also, knowing the working BIND version determines how to
	# handle TTL values.  Specifically, symbolic TTL values
	# were not supported until version 8.2.1.  If our version
	# of BIND is an earlier one or can not be determined, all
	# TTL values will be converted into their equivalent number
	# of seconds.
	#
        $Host = ($RespHost eq ".") ?? "127.0.0.1" !! $RespHost;
	GET_BIND_VERSION($Host);
	if ($BIND_Version_Num) {
	    if ($BIND_Version_Num < 80200) {
		#
		# Disable the generation of $TTL directives in the MAKE_SOA
		# subroutine by negating the "$RFC_2308" flag to the "hard"
		# value of 0 regardless of what was specified in a -o/+t
		# option.  $TTL directives in existing DB files will be
		# effectively removed.
		#
		$RFC_2308 = 0;

		# NOTE: If a value for "$Master_Ttl" was specified with a
		#       -o/+t option, transfer the value to its proper
		#       context in the SOA MINIMUM field, "$Ttl".
		#       Otherwise, a -o "$Ttl" argument will take effect
		#       in the MAKE_SOA subroutine or, if no "$Ttl" was
		#       specified, the value of "$DefTtl" will take effect.
		#       In either case, any RFC-2308 Negative Caching value
		#       that may have been specified with -o/+t is cancelled.
		#
		$Ttl = $Master_Ttl if $Master_Ttl;
	    } else {
		#
		# The detected BIND version implements RFC-2308 and so $TTL
		# directives must always be present in every zone file.
		#
		unless ($RFC_2308) {
		    #
		    # RFC-2308 status was toggled off by a -o option that
		    # specified exactly four arguments.  If a value for
		    # "$Ttl" was specified, transfer the value to its
		    # proper context in "$Master_Ttl".  Otherwise, existing
		    # $TTL directives will retain their values or be created
		    # with the value of "$DefTtl".
		    #
		    $Master_Ttl = $Ttl if $Ttl;

		    # The MAKE_SOA subroutine will use the SOA time intervals
		    # from an already-existing DB file in the absence of
		    # replacement values via a -o/+t option.  Since a positive
		    # RFC-2308 status from the detected BIND version overrides
		    # the negated status set by the -o option, it is best to
		    # make the following assumptions:
		    #
		    #   1. The name server was upgraded to BIND 8.2 or newer
		    #      and the -o option was not updated to reflect this.
		    #
		    #   2. The existing DB files still have SOA RRs with the
		    #      SOA Minimum fields in their old context of holding
		    #      a positive TTL value.
		    #
		    # In order to make sure that existing SOA Minimum fields
		    # assume their new context, we'll explicitly set "$Ttl"
		    # as though a value had been passed via the -o/+t option
		    # in an RFC-2308 context.  The SOA RRs will thus be
		    # initialized with the default recommended value for the
		    # negative cache interval.
		    #
		    $Ttl = $DefNegCache;
		}
		# Make sure the generation of $TTL directives is unequivocally
		# forced by setting the "$RFC_2308" flag to a "hard" value of 2.
		#
		$RFC_2308 = 2;
	    }
	} else {
	    #
	    # The version of BIND running on the master name server (-h option)
	    # can not be determined.  Either the BIND daemon is not running or
	    # the version ID may have been altered in the configuration file
	    # or an altered version of the special RR `version.bind.   CH TXT'
	    # may have been created.
	    #
	    if ($RFC_2308) {
		#
		# Either no -o/+t option was specified ("$RFC_2308" starts out
		# with a default value of 1 at the start of the program), a
		# -o option did not toggle the RFC-2308 status to false, and/or
		# a +t option forced RFC-2308 to be assumed.
		# Make sure the generation of $TTL directives is unequivocally
		# forced by setting the "$RFC_2308" flag to a "hard" value of 2.
		#
		$RFC_2308 = 2;
	    } else {
		#
		# RFC-2308 status was toggled off by a -o option that
		# specified exactly four arguments.  Even though we don't
		# know which version of BIND we're running, our RFC-2308
		# override policy is that an existing $TTL directive which
		# is discovered by the MAKE_SOA subroutine will toggle the
		# RFC-2308 status back to true.
		# Allow this possible change to take place by setting the
		# "$RFC_2308" flag to the "soft" value of 1.
		#
		$RFC_2308 = 1;
	    }
	}
    }
    return;
}



#
# Subroutine for obtaining the version string of a BIND name server.
# The following global variables are set:
#
#   $BIND_Version     : Actual version string
#   $BIND_Version_Num : Numerical version value for use in comparisons
#   $BIND_Ver_Msg     : List of bugs which the BIND version may have
#
sub GET_BIND_VERSION {
    my ($nameserver) = @_;
    my ($bind48_bug_tokens, $bind_bugs, $cert_url_refs, $continuation_line);
    my ($major_version, $minor_version, $patch_version, $query_options);
    my ($release_token, $status, $tmp_version);
    local *DIGOUT;

    $bind48_bug_tokens = $bind_bugs = $BIND_Ver_Msg = $cert_url_refs
		       = $continuation_line = $status = "";
    $BIND_Version_Num = 0;
    if (defined($Debug_BIND_Version)) {
	$BIND_Version = $Debug_BIND_Version;
    } else {
	$BIND_Version = "unavailable";
	return if $DiG_Version_Num == 0;
	$query_options = "+nostats +norec +$DiG_Timeout +$DiG_Retries"
			 . " \@$nameserver version.bind txt chaos";
	unless (open(*DIGOUT, '-|', "$DiG $query_options 2>&1")) {
	    return;
	}
	while (<DIGOUT>) {
	    chop;
	    next if /^$/;
	    if (/^;.+HEADER.+opcode: QUERY, status: ([^,]+)/) {
		$status = $1;
		if ($status ne 'NOERROR') {
		    if ($status ~~ /^(?:NOTIMPL?|FORMERR)$/) {
			#
			# We are probably dealing with a non-BIND name server.
			# Microsoft -> NOTIMP
			# djbdns    -> FORMERR
			#
			$BIND_Version = "*Non-BIND NS*";
		    } else {
			$BIND_Version = $status;
		    }
		    last;
		}
	    } elsif (/^VERSION[.]BIND[.]\s+.*TXT\s+\"([^\"]*)/i) {
		$BIND_Version = $1;
		if ($BIND_Version ~~ /\\$/) {
		    $BIND_Version ~~ s/(\s+)\\$/$1/;  # remove pre-spaced escape
		    $BIND_Version ~~ s/\\$/ /;	      # escape -> space char.
		    $continuation_line = "1";
		    next;
		} else {
		    $BIND_Version = "unavailable" if $BIND_Version ~~ /^\s*$/;
		    last;
		}
	    } elsif ($continuation_line && /([^\"]*)/) {
		$continuation_line = $1;
		$continuation_line ~~ s/^\s+//;
		$BIND_Version .= $continuation_line;
		if ($BIND_Version ~~ /\\$/) {
		    $BIND_Version ~~ s/(\s+)\\$/$1/;
		    $BIND_Version ~~ s/\\$/ /;
		    next;
		} else {
		    $BIND_Version = "unavailable" if $BIND_Version ~~ /^\s*$/;
		    last;
		}
	    }
	}
	close(*DIGOUT);
	return unless $status eq "NOERROR";
    }

    if ($BIND_Version ~~ /^(\d+)[.](\d+)([.](\d+))?(.*)/) {
	$major_version = (defined $1) ?? $1 !! 0;
	$minor_version = (defined $2) ?? $2 !! 0;
	$patch_version = (defined $4) ?? $4 !! 0;
	$release_token = (defined $5) ?? $5 !! "";
	$BIND_Version_Num = (10000 * $major_version)
			    + (100 * $minor_version) + $patch_version;
    }
    if ($BIND_Version_Num < 90000 && $BIND_Version ~~ /[48][.]\d/) {
	#
	# See if "$BIND_Version" resembles the format of a standard BIND
	# version string.  If so, we'll massage the text a bit and check
	# "%BIND_Bug_Index" for any security-related defects to which
	# this version may be vulnerable.
	# NOTE: Here are the samples of customized BIND version
	#       strings that have been seen so far:
	#
	#       "named 8.2.3 for Multinet V4.3 Process Software"
	#	"Meta IP/DNS V4.1 - BIND V8.1.2 (Build 4704 )"
	#
	$tmp_version = $BIND_Version;
	for ($tmp_version) {
	    s/.*(?:named|BIND) //i;		# remove these prepended titles
	    s/^V(?:ers?i?o?n ?)?(\d)/$1/i;	# remove custom prepended text
	    s/(\d)[.-]REL.*/$1/i;		# truncate "-RELease"
	    s/(\d)\s*\(.*\)$/$1/;		# remove custom appended text
	    s/(\d)[.-][PT](\d).*/$1-P$2/i;	# standardize Test & Beta vers.
	    s/^8.2.3-P.*/8.2.3-T/;		# standardize 8.2.3-T?? versions
	}
	if ($BIND_Version_Num == 0
	    && $tmp_version ~~ /^(\d+)[.](\d+)([.](\d+))?/) {
	    #
	    # Now that the customized version string has undergone an
	    # attempted cleanup, make another stab at determining the
	    # equivalent numerical version.
	    #
	    $major_version = (defined $1) ?? $1 !! 0;
	    $minor_version = (defined $2) ?? $2 !! 0;
	    $patch_version = (defined $4) ?? $4 !! 0;
	    $BIND_Version_Num = (10000 * $major_version)
				+ (100 * $minor_version) + $patch_version;
	}
	if (exists($BIND_Bug_Index{$tmp_version})) {
	    $bind48_bug_tokens = $BIND_Bug_Index{$tmp_version};
	    for ($bind48_bug_tokens) {
		s/(\S+) /$1, /g;
		s/^([^,]+), ([^,]+)$/$1 & $2/;
		s/, ([^,]+)$/, & $1/;
	    }
	    $cert_url_refs = "     $CERT_URL_bugs,\n";
	}
	if (($BIND_Version_Num >= 40803 && $BIND_Version_Num < 40909) ||
	    ($BIND_Version_Num >= 80000 && $BIND_Version_Num < 80206) ||
	    ($BIND_Version_Num >= 80300 && $BIND_Version_Num < 80303)) {
	    $bind_bugs = "libbind buffer overflow, ";
	    $cert_url_refs .= "     $CERT_URL_libbind,\n";
	}
	if ($BIND_Version_Num >= 40902 && $BIND_Version_Num <= 40910) {
	    $bind_bugs .= "LIBRESOLV: buffer overrun, ";
	}
	if (($BIND_Version_Num >= 80200 && $BIND_Version_Num <= 80206) ||
	    ($BIND_Version_Num >= 80300 && $BIND_Version_Num <= 80303)) {
	    $bind_bugs .= "BIND: Multiple Denial of Service, ";
	}
	if (($BIND_Version_Num >= 40905 && $BIND_Version_Num <= 40910) ||
	    ($BIND_Version_Num >= 80100 && $BIND_Version_Num <= 80206) ||
	    ($BIND_Version_Num >= 80300 && $BIND_Version_Num <= 80303)) {
	    $bind_bugs .= "BIND: Remote Execution of Code, ";
	}
	if ($bind_bugs ~~ /(?:LIBRESOLV|BIND): /) {
	    $cert_url_refs .= "     $CERT_URL_buf_DoS,\n";
	}
	if ((($BIND_Version_Num >= 80000 && $BIND_Version_Num < 80307) &&
	     ($tmp_version !~ /(?:8.1.3|8.2.2-P8|8.2.4-P1|8.2.5-P1)/)) ||
	    ($BIND_Version_Num >= 80400 && $BIND_Version_Num < 80403)) {
	    $bind_bugs .= "BIND: Negative Cache DoS, ";
	    $cert_url_refs .= "     $CERT_URL_negcache,\n";
	}
	if ($BIND_Version_Num >= 80404 && $BIND_Version_Num <= 80405) {
	    $bind_bugs .= "BIND: q_usedns Array Overrun, ";
	    $cert_url_refs .= "     $CERT_URL_overrun,\n";
	}
    } elsif ($BIND_Version_Num >= 90000) {
	#
	# BIND 9 version strings have a more standard format than BIND 8.
	#
	if ($BIND_Version_Num >= 90100 && $BIND_Version_Num < 90200) {
	    #
	    # These versions of BIND included a vulnerable version
	    # of the OpenSSL library and were automatically linked
	    # to it.  BIND versions 9.2.X and later may be affected
	    # if optionally linked to a vulnerable OpenSSL library
	    # with the `--with-openssl=libpath' configuration option.
	    #
	    $bind_bugs = "OpenSSL buffer overflow, ";
	    $cert_url_refs = "     $CERT_URL_openssl,\n";
	}
	if ($BIND_Version_Num < 90201 ||
	    ($BIND_Version_Num == 90201 && $release_token)) {
	    $bind_bugs .= "DoS internal consistency check, ";
	    $cert_url_refs .= "     $CERT_URL_DoS,\n";
	}
	if ($BIND_Version_Num >= 90200 && $BIND_Version_Num <= 90201) {
	    #
	    # This release of BIND may be vulnerable to the
	    # `libbind buffer overflow' bug if configured with
	    # the `--enable-libbind' option.
	    #
	    $bind_bugs .= "libbind buffer overflow, ";
	    $cert_url_refs .= "     $CERT_URL_libbind,\n";
	}
	if ($BIND_Version_Num == 90300) {
	    $bind_bugs .= "BIND: Self Check Failing, ";
	    $cert_url_refs .= "     $CERT_URL_selfcheck,\n";
	}
    }
    if ($cert_url_refs) {
	$cert_url_refs ~~ s/,\n$//;
	unless ($cert_url_refs ~~ /,/) {
	    #
	    # Just one CERT advisory to report.
	    #
	    $bind_bugs ~~ s/, $//;
	    $bind_bugs = $bind48_bug_tokens . $bind_bugs;
	    $BIND_Ver_Msg = " $bind_bugs.\n"
			  . " See $ISC_URL and\n"
			  . "$cert_url_refs for details.";
	} else {
	    if ($bind48_bug_tokens) {
		$bind48_bug_tokens ~~ s/,? &/,/;
		$bind48_bug_tokens .= ",\n ";
	    }
	    $bind_bugs ~~ s/([^,]+,[^,]+,)/$1\n/gm;	# Insert newline after
	    $bind_bugs ~~ s/,?. $//s;			# every other entry.
	    $bind_bugs = $bind48_bug_tokens . $bind_bugs;
	    $cert_url_refs ~~ s/(.+),\n(.+)/$1, and\n$2/s;
	    $BIND_Ver_Msg = " $bind_bugs.\n"
			  . " See $ISC_URL,\n"
			  . "$cert_url_refs for details.";
	}
    }
    return;

}



#
# Subroutine to look for a special configuration file that holds the
# network connectivity information for computer running `h2n' and
# other customizable values.  The file search order is:
#
#   $HOME/.h2nrc
#   $PWD/h2n.conf
#   /etc/h2n.conf
#   /etc/local/h2n/h2n.conf
#   /etc/opt/h2n/h2n.conf
#   /usr/local/etc/h2n.conf
#
# If found, the data contained therein will replace the built-in values
# of the following global data structures:
#
#   @Local_Networks
#   @Local_Subnetmasks
#   $DiG
#   $Check_Del
#   $DiG_Retries
#   $DiG_Timeout
#
sub READ_RCFILE {
    my ($buffer, $cidr_size, $cwd, $data, $error, $file, $first_net_token);
    my ($line_num, $mask_size, $netmask, $network, $options_file, $subnet_mask);
    my @conf_paths = (".h2nrc", "./h2n.conf", "/etc/h2n.conf",
		      "/etc/local/h2n/h2n.conf", "/etc/opt/h2n/h2n.conf",
		      "/usr/local/etc/h2n.conf");

    $first_net_token = 1;
    $line_num = 0;
    $options_file = "";
    $cwd = getcwd();
    chdir;				# change to the user's $HOME
    foreach $file (@conf_paths) {
	if (-f $file && -r $file && -s $file && open(*CONF, '<', $file)) {
	    $file = "\$HOME/$file" if $file eq ".h2nrc";
	    while (<CONF>) {
		$line_num++;
		chop;
		s/^\s+//;
		next if /^#/ || /^$/;
		s/#.*//;
		s/\s+$//;

		if (/^LOCAL-NETWORKS\s*=/i) {
		    if ($first_net_token) {
			@Local_Networks = ();
			@Local_Subnetmasks = ();
			$first_net_token = 0;
		    }
		    s/^LOCAL-NETWORKS\s*=\s*//i;
		    ($buffer = $_) ~~ s/,/ /g;
		    while ($buffer) {
			($data, $buffer) = split(' ', $buffer, 2);
			($data, $subnet_mask) = split(/:/, $data, 2);
			$subnet_mask = "" unless defined($subnet_mask);
			($network, $cidr_size) = split('/', $data, 2);
			$cidr_size = 0 unless defined($cidr_size);
			if ($data eq "0/0") {
			    $subnet_mask = "0.0.0.0";
			} else {
			    $netmask = undef;
			    $error = CHECK_NET(\$network, \$cidr_size,
					       \$netmask);
			    if ($error) {
				print STDERR "Ignoring bad LOCAL-NETWORKS ",
					     "value ($data) at line ",
					     "$line_num\nin configuration ",
					     "file `$file':\n";
				print STDERR $error;
				next;
			    } else {
				#
				# Re-initialize "$data" in case the network-
				# portion of the specification was normalized.
				#
				$data = "$network/$cidr_size";
				unless ($subnet_mask) {
				    $subnet_mask = $netmask;
				} else {
				    $mask_size = undef;
				    $error = CHECK_NET(undef, \$mask_size,
						       \$subnet_mask);
				    if ($error || $mask_size < $cidr_size) {
					print STDERR "Ignoring bad ",
						     "LOCAL-NETWORKS value ",
						     "($data) at line ",
						     "$line_num\nin ",
						     "configuration file ",
						     "`$file':\n";
					if ($error) {
					    print STDERR $error;
					} else {
					    print STDERR " The number of mask ",
							 "bits is fewer than ",
							 "that of the ",
							 "corresponding ",
							 "network.\n";
					}
					next;
				    }
				}
			    }
			}
			push(@Local_Networks, $data);
			push(@Local_Subnetmasks, $subnet_mask);
		    }

		} elsif (/^DIG-UTILITY\s*=/i) {
		    s/^DIG-UTILITY\s*=\s*//i;
		    if ($_ ~~ /\//) {
			if (! -e $_) {
			    print STDERR "Non-existent file for DIG-UTILITY ",
					 "at line $line_num\nin configuration ",
					 "file `$file'\n";
			} elsif (! -x $_) {
			    print STDERR "Non-executable file for DIG-UTILITY ",
					 "at line $line_num\nin configuration ",
					 "file `$file'\n";
			} else {
			    $DiG = $_;
			}
		    } else {
			$DiG = $_;
		    }

		} elsif (/^CHECK_DEL-UTILITY\s*=/i) {
		    s/^CHECK_DEL-UTILITY\s*=\s*//i;
		    if ($_ ~~ /\//) {
			if (! -e $_) {
			    print STDERR "Non-existent file for ",
					 "CHECK_DEL-UTILITY at line ",
					 "$line_num\nin configuration ",
					 "file `$file'\n";
			} elsif (! -x $_) {
			    print STDERR "Non-executable file for ",
					 "CHECK_DEL-UTILITY at line ",
					 "$line_num\nin configuration ",
					 "file `$file'\n";
			} else {
			    $Check_Del = $_;
			}
		    } else {
			$Check_Del = $_;
		    }

		} elsif (/^DIG-RETRY-LIMIT\s*=/i) {
		    s/^DIG-RETRY-LIMIT\s*=\s*//i;
		    if (/^\d+$/) {
			$DiG_Retries = $_;
		    } else {
			print STDERR "Non-numeric value for DIG-RETRY-LIMIT ",
				     "at line $line_num\nin configuration ",
				     "file `$file'\n";
		    }

		} elsif (/^DIG-TIMEOUT-LIMIT\s*=/i) {
		    s/^DIG-TIMEOUT-LIMIT\s*=\s*//i;
		    if (/^\d+$/) {
			$DiG_Timeout = $_;
		    } else {
			print STDERR "Non-numeric value for DIG-TIMEOUT-LIMIT ",
				     "at line $line_num\nin configuration ",
				     "file `$file'\n";
		    }

		} elsif (/^DB-GLUELESS-LIMIT\s*=/i) {
		    s/^DB-GLUELESS-LIMIT\s*=\s*//i;
		    if (/^\d+$/) {
			if ($_ <= $Glueless_Upper_Limit) {
			    $DB_Glueless_Limit = $_;
			} else {
			    print STDERR "Excessive value for ",
					 "DB-GLUELESS-LIMIT at line ",
					 "$line_num\nin configuration ",
					 "file `$file'\n";
			}
		    } else {
			print STDERR "Non-numeric value for DB-GLUELESS-LIMIT ",
				     "at line $line_num\nin configuration ",
				     "file `$file'\n";
		    }

		} elsif (/^VERIFY-GLUELESS-LIMIT\s*=/i) {
		    s/^VERIFY-GLUELESS-LIMIT\s*=\s*//i;
		    if (/^\d+$/) {
			if ($_ <= $Glueless_Upper_Limit) {
			    $Verify_Glueless_Limit = $_;
			} else {
			    print STDERR "Excessive value for ",
					 "VERIFY-GLUELESS-LIMIT at line ",
					 "$line_num\nin configuration ",
					 "file `$file'\n";
			}
		    } else {
			print STDERR "Non-numeric value for ",
				     "VERIFY-GLUELESS-LIMIT at line ",
				     "$line_num\nin configuration ",
				     "file `$file'\n";
		    }

		} elsif (/^[^-+]/) {
		    print STDERR "Unrecognized data ($_) at line ",
				 "$line_num\nin configuration ",
				 "file `$file' - ignored.\n";

		} else {
		    #
		    # Assume that this line contains one or more `h2n'
		    # options that the user wishes to set as defaults
		    # without typing them on the command line or specifying
		    # them in a separate `-f' options file.
		    # Store the options in a temporary file for later
		    # submission to the PARSE_ARGS() subroutine.
		    #
		    unless ($options_file) {
			($data = $file) ~~ s/.*\/[.]?//;
			$options_file = "$Debug_DIR/${data}_options";
			unless (OPEN(*OPT, '>', $options_file)) {
			    print STDERR "While processing command-line ",
					 "options found in the $Program ",
					 "configuration file\n($file), trying ",
					 "to open the temporary working ",
					 "file\n`$options_file' failed with ",
					 "the following error:\n  $!\n";
			    close(*CONF);
			    GIVE_UP();
			}
		    }
		    print OPT "$_\n";
		}
	    }
	    #
	    # Save the unique identity (device and inode)
	    # of the just-processed configuration file.
	    #
	    $RCfile = join(":", (stat(*CONF))[0..1]);
	    close(*CONF);
	    $data = $file;	# save $file before exiting `foreach' loop
	    last;		# don't read any more configuration files
	}
	chdir $cwd if $file eq ".h2nrc";
    }
    chdir $cwd;		# make sure we're back to our original directory
    unless (@Local_Networks) {
	#
	# Reassign the default values in case they got erased
	# by empty text in an `h2n' configuration file.
	#
	@Local_Networks = ("0/0");
	@Local_Subnetmasks = ("0.0.0.0");
    }
    if ($options_file) {
	close(*OPT);
	$error = PARSE_ARGS(("-f", $options_file));
	if ($error) {
	    if ($error == 1) {
		print STDERR "NOTE: The above message was generated from ",
			     "an erroneous command-line option\n";
	    } else {
		print STDERR "NOTE: The above messages were generated from ",
			     "erroneous command-line options\n";
	    }
	    print STDERR "      found in the file `$data'.\nPlease make ",
			 "the necessary correction(s).\n";
	    exit(2);
	} elsif (!$Debug) {
	    unlink($options_file);
	}
    }
    return;
}



sub GET_LOCAL_NETINFO {
    my ($addr, $i, $netbits, $netmask, $network, $our_host, $tmp);

    # In order to verify a domain, a zone transfer must be obtained from
    # one of the domain's listed name servers.  This program will use DiG
    # to get every IP address of every listed name server so that they can
    # all be tried in a zone transfer request before having to give up.
    # Some IP addresses, however, may belong to inaccessible interfaces
    # of multi-homed bastion hosts.  Requesting a zone transfer from such
    # IP addresses will cause cause this program to hang until the connection
    # request times out.  We'll try to avoid these delays by sorting the
    # IP addresses using the information in the site-specific global arrays
    #
    #   @Local_Networks
    #   @Local_Subnetmasks
    #
    # This subroutine will initialize the following global arrays:
    #
    #   @Our_Nets
    #   @Our_Netbits
    #   @Our_Subnetmasks
    #   @Our_Subnets
    #
    # This information will allow any IP address to be sorted into one
    # of the following four categories:
    #
    #   1) the localhost itself
    #   2) subnets to which the localhost is directly connected
    #   3) networks to which the localhost has known connectivity
    #   4) all other networks
    #
    $our_host = hostname();
    ($tmp, $tmp, $tmp, $tmp, @Our_Addrs) = gethostbyname($our_host);

    # The "@Our_Addrs" array returned by the gethostbyname() function
    # contains the IP address(es) of the local host.  Each IP address
    # is a binary structure consisting of four unsigned character values.
    # We'll use the pack() and unpack() function with a template of `C4'
    # to do the necessary data manipulations.
    #
    # First, add the loopback address as a local host address.
    #
    push(@Our_Addrs, pack('C4', "127", "0", "0", "1"));
    @Our_Nets = @Our_Netbits = @Our_Subnetmasks = @Our_Subnets = ();
    for ($i = 0; $i < @Local_Networks; $i++) {
	#
	# Create the corresponding network-related packed data structures.
	#
	($network, $netbits) = split('/', $Local_Networks[$i], 2);
	$network .= ".0.0.0";			# ensure a 4-octet format
	$Our_Nets[$i] = pack('C4', split(/[.]/, $network));
	$netmask = ((2 ** $netbits) - 1) << (32 - $netbits);

	# Convert the above 32-bit "$netmask" variable to a packed `C4'
	# data structure so that it will be compatible for bitwise AND
	# operations with the other IP-based data structures.
	#
	$Our_Netbits[$i] = pack('C4', ($netmask & 0xff000000) >> 24,
				      ($netmask & 0x00ff0000) >> 16,
				      ($netmask & 0x0000ff00) >> 8,
				       $netmask & 0x000000ff);

	# Each network specified in "@Local_Networks" will have a
	# corresponding subnet mask in "@Local_Subnetmasks".
	#
	$netmask = $Local_Subnetmasks[$i];
	$Our_Subnetmasks[$i] = pack('C4', split(/[.]/, $netmask, 4));
	$Our_Subnets[$i] = "";		# create defined values for all indices
    }
    foreach $addr (@Our_Addrs) {
	#
	# Find all subnets to which the local host is directly connected.
	#
	for ($i = 0; $i < @Our_Netbits; $i++) {
	    $network = $addr & $Our_Netbits[$i];
	    if ($network eq $Our_Nets[$i]) {
		$Our_Subnets[$i] = $addr & $Our_Subnetmasks[$i];
		last;
	    }
	}
    }
    return;
}



sub GEN_BOOT {
    my ($bcname, $bootdb, $bootdom, $bootzone, $dir, $format);
    my ($line, $one, $spcl_file, @search_path);

    # The `h2n' program has a feature whereby it will look for
    # a file with one of the following names:
    #
    #   spcl-boot  spcl-boot.sec  spcl-boot.sec.save
    #
    # and append its contents the corresponding BIND 4 boot file
    # that this subroutine builds.  Likewise for BIND 8/9, a file
    # called:
    #
    #   spcl-conf  spcl-conf.sec  spcl-conf.sec.save
    #
    # will be appended to the corresponding configuration file
    # via an `include' statement.  The directory search order
    # for finding these files is:
    #
    #   1. $Boot_Dir  [-B option]
    #   2. getcwd()   [current directory]
    #
    # The -B option is the preferred method for the sake of logical
    # consistency but the CWD is also searched for backwards compatibility.
    #
    @search_path = ($Boot_Dir, getcwd());

    unless (-e "boot.cacheonly") {
	$bcname = ($Bootfile eq "/dev/null") ?? $Bootfile
					     !! "$Boot_Dir/boot.cacheonly";
	unless (open(*F, '>', $bcname)) {
	    print STDERR "Unable to write `$bcname': $!\n",
			 "Check your -B option argument.\n";
	    GIVE_UP();
	}
	print F "\ndirectory  $DB_Dir\n\n",
		"cache      .\t\t\t\tdb.cache\n",
		"primary    0.0.127.in-addr.arpa\t\tdb.127.0.0\n";
	close(*F);
    }

    unless (-e "conf.cacheonly") {
	$bcname = ($Conffile eq "/dev/null") ?? $Conffile
					     !! "$Boot_Dir/conf.cacheonly";
	unless (open(*F, '>', $bcname)) {
	    print STDERR "Unable to write `$bcname': $!\n",
			 "Check your -B option argument.\n";
	    GIVE_UP();
	}
	print F "\noptions {\n",
		"\tdirectory \"$DB_Dir\";\n};\n\n";
	if ($NeedHints) {
	    if ($New_Fmt_Conffile) {
		print F "zone \".\" {\n\ttype hint;\n\tfile \"db.cache\";",
			"\n};\n";
	    } else {
		print F "zone \".\"\t\t\t{ type hint;\tfile \"db.cache\"; };\n";
	    }
	}
	if ($New_Fmt_Conffile) {
	    print F "zone \"0.0.127.in-addr.arpa\" {\n\ttype master;\n",
		    "\tfile \"db.127.0.0\";\n};\n";
	} else {
	    print F "zone \"0.0.127.in-addr.arpa\"\t{ type master;",
		    "\tfile \"db.127.0.0\"; };\n";
	}
	close(*F);
    }

    $bcname = ($Bootfile eq "/dev/null") ?? $Bootfile !! "$Boot_Dir/$Bootfile";
    unless (open(*F, '>', $bcname)) {
	print STDERR "Unable to write `$bcname': $!\n",
		     "Check your -B and/or -b option argument(s).\n";
	GIVE_UP();
    }
    print F "\n";
    foreach $line (@Boot_Opts) {
	printf F "%s\n", $line;
    }
    print F "\ndirectory  $DB_Dir\n\n",
	    "cache      .\t\t\t\tdb.cache\n";
    if ($MakeLoopbackZone) {
	print F "primary    0.0.127.in-addr.arpa\t\tdb.127.0.0\n";
    }
    foreach $line (@Boot_Msgs) {
	($bootdom, $bootdb) = split(' ', $line, 2);
	printf F "primary    %s%s\n", TAB($bootdom, 29), $bootdb;
    }
    $spcl_file = "spcl-boot";
    foreach $dir (@search_path) {
	next unless -e "$dir/$spcl_file";
	$spcl_file = "$dir/$spcl_file";
	last;
    }
    if (-r $spcl_file) {
	unless (open(*ADD, '<', $spcl_file)) {
	    print STDERR "Unable to read `$spcl_file': $!\n";
	    GIVE_UP();
	}
	printf F "\n; ----- Begin contents of file `$spcl_file' -----\n\n";
	while (<ADD>) {
	    print F;
	}
	close(*ADD);
	printf F "\n; ----- End of appended file `$spcl_file' -----\n\n";
	if ($Verbose) {
	    print STDOUT "File `$spcl_file' found and appended to `$bcname'.\n";
	}
    }
    close(*F);

    $bcname = ($Conffile eq "/dev/null") ?? $Conffile !! "$Boot_Dir/$Conffile";
    unless (open(*F, '>', $bcname)) {
	print STDERR "Unable to write `$bcname': $!\n",
		     "Check your -B and/or +c option argument(s).\n";
	GIVE_UP();
    }
    if ($Conf_Prefile) {
	print F "\ninclude \"$Conf_Prefile\";\n";
    }
    if ($CustomLogging) {
	if (@Conf_Logging) {
	    print F "\nlogging {\n";
	    foreach $line (@Conf_Logging) {
		printf F "\t%s\n", $line;
	    }
	    print F "};\n\n";
	} else {
	    print F "\nlogging {\n",
		    "\tcategory lame-servers { null; };\n",
		    "\tcategory cname { null; };\n",
		    "\tcategory security { default_syslog; };\n",
		    "};\n\n";
	}
    }
    if ($CustomOptions) {
	if (@Conf_Opts) {
	    print F "\n" unless $CustomLogging;
	    print F "options {\n",
		    "\tdirectory \"$DB_Dir\";\n";
	    foreach $line (@Conf_Opts) {
		printf F "\t%s\n", $line;
	    }
	    print F "};\n\n";
	}
    } else {
	print F "\n" unless $CustomLogging;
	print F "options {\n",
		"\tdirectory \"$DB_Dir\";\n",
		"};\n\n";
    }
    if ($NeedHints) {
	if ($New_Fmt_Conffile) {
	    print F "zone \".\" {\n\ttype hint;\n\tfile \"db.cache\";\n};\n";
	} else {
	    print F "zone \".\"\t\t\t{ type hint;\tfile \"db.cache\"; };\n";
	}
    } elsif ($Conf_Prefile) {
	print F "\n" unless $CustomLogging;
    }
    if ($MakeLoopbackZone) {
	if ($New_Fmt_Conffile) {
	    print F "zone \"0.0.127.in-addr.arpa\" {\n\ttype master;\n",
		    "\tfile \"db.127.0.0\";\n};\n";
	} else {
	    print F "zone \"0.0.127.in-addr.arpa\"\t{ type master;",
		    "\tfile \"db.127.0.0\"; };\n";
	}
    }
    foreach $line (@Boot_Msgs) {
	($bootdom, $bootdb) = split(' ', $line, 2);
	if ($New_Fmt_Conffile) {
	    printf F "zone \"%s\" {\n\ttype master;\n\tfile \"%s\";",
		     $bootdom, $bootdb;
	    foreach $one (@Global_Master_Zone_Opts) {
		printf F "\n\t%s", $one;
	    }
	    if (exists($Master_Zone_Opt{"$bootdb"})) {
		foreach $one (split('\n', $Master_Zone_Opt{"$bootdb"})) {
		    printf F "\n\t%s", $one;
		}
	    }
	    printf F "\n};\n";
	} else {
	    printf F "zone %s{ type master;\tfile \"%s\";",
		     TAB("\"$bootdom\"", 27), $bootdb;
	    foreach $one (@Global_Master_Zone_Opts) {
		printf F "\n                                  %s", $one;
	    }
	    if (exists($Master_Zone_Opt{"$bootdb"})) {
		foreach $one (split('\n', $Master_Zone_Opt{"$bootdb"})) {
		    printf F "\n                                  %s", $one;
		}
	    }
	    printf F " };\n";
	}
    }
    $spcl_file = "spcl-conf";
    foreach $dir (@search_path) {
	next unless -e "$dir/$spcl_file";
	$spcl_file = "$dir/$spcl_file";
	last;
    }
    if (-r $spcl_file) {
	print F "\ninclude \"$spcl_file\";\n\n";
    }
    close(*F);

    if (defined($BootSecAddr)) {
	$bcname = "$Boot_Dir/boot.sec";
	unless (open(*F, '>', $bcname)) {
	    print STDERR "Unable to write `$bcname': $!\n",
			 "Check your -B and/or -Z option argument(s).\n";
	    GIVE_UP();
	}
	print  F "\n";
	foreach $line (@Boot_Opts) {
	    printf F "%s\n", $line;
	}
	print  F "\ndirectory  $DB_Dir\n\n",
		 "cache      .\t\t\t\tdb.cache\n";
	if ($MakeLoopbackZone) {
	    print  F "primary    0.0.127.in-addr.arpa\t\tdb.127.0.0\n";
	}
	foreach $line (@Boot_Msgs) {
	    ($bootdom, $bootdb) = split(' ', $line, 2);
	    printf F "secondary  %s%s\n", TAB($bootdom, 29), $BootSecAddr;
	}
	$spcl_file = "spcl-boot.sec";
	foreach $dir (@search_path) {
	    next unless -e "$dir/$spcl_file";
	    $spcl_file = "$dir/$spcl_file";
	    last;
	}
	if (-r $spcl_file) {
	    unless (open(*ADD, '<', $spcl_file)) {
		print STDERR "Unable to read `$spcl_file': $!\n";
		GIVE_UP();
	    }
	    printf F "\n; ----- Begin contents of file `$spcl_file' -----\n\n";
	    while (<ADD>) {
		print F;
	    }
	    close(*ADD);
	    printf F "\n; ----- End of appended file `$spcl_file' -----\n\n";
	    if ($Verbose) {
		print STDOUT "File `$spcl_file' found and appended to ",
			     "`$bcname'.\n";
	    }
	}
	close(*F);
    }

    if (defined($ConfSecAddr)) {
	$bcname = "$Boot_Dir/conf.sec";
	unless (open(*F, '>', $bcname)) {
	    print STDERR "Unable to write `$bcname': $!\n",
			 "Check your -B and/or -Z option argument(s).\n";
	    GIVE_UP();
	}
	if ($Conf_Prefile) {
	    print F "\ninclude \"$Conf_Prefile\";\n";
	}
	if ($CustomLogging) {
	    if (@Conf_Logging) {
		print  F "\nlogging {\n";
		foreach $line (@Conf_Logging) {
		    printf F "\t%s\n", $line;
		}
		print  F "};\n\n";
	    } else {
		print  F "\nlogging {\n",
			 "\tcategory lame-servers { null; };\n",
			 "\tcategory cname { null; };\n",
			 "\tcategory security { default_syslog; };\n",
			 "};\n\n";
	    }
	}
	if ($CustomOptions) {
	    if (@Conf_Opts) {
		print F "\n" unless $CustomLogging;
		print F "options {\n",
			"\tdirectory \"$DB_Dir\";\n";
		foreach $line (@Conf_Opts) {
		    printf F "\t%s\n", $line;
		}
		print F "};\n\n";
	    }
	} else {
	    print F "\n" unless $CustomLogging;
	    print F "options {\n",
		    "\tdirectory \"$DB_Dir\";\n",
		    "};\n\n";
	}
	if ($NeedHints) {
	    if ($New_Fmt_Conffile) {
		print F "zone \".\" {\n\ttype hint;\n\tfile \"db.cache\";",
			"\n};\n";
	    } else {
		print F "zone \".\"\t\t\t{ type hint;\tfile \"db.cache\"; };\n";
	    }
	} elsif ($Conf_Prefile) {
	    print F "\n" unless $CustomLogging;
	}
	if ($MakeLoopbackZone) {
	    if ($New_Fmt_Conffile) {
		print F "zone \"0.0.127.in-addr.arpa\" {\n\ttype master;\n",
			"\tfile \"db.127.0.0\";\n};\n";
	    } else {
		print F "zone \"0.0.127.in-addr.arpa\"\t{ type master;",
			"\tfile \"db.127.0.0\"; };\n";
	    }
	}
	foreach $line (@Boot_Msgs) {
	    ($bootdom, $bootzone) = split(' ', $line, 2);
	    if ($New_Fmt_Conffile) {
		printf F "zone \"%s\" {\n\ttype slave;\n\tmasters { %s };",
			 $bootdom, $ConfSecAddr;
		foreach $one (@Global_Slave_Zone_Opts) {
		    printf F "\n\t%s", $one;
		}
		if (exists($Slave_Zone_Opt{"$bootzone"})) {
		    foreach $one (split('\n', $Slave_Zone_Opt{"$bootzone"})) {
			printf F "\n\t%s", $one;
		    }
		}
		printf F "\n};\n";
	    } else {
		printf F "zone %s{ type slave;\tmasters { %s };",
			 TAB("\"$bootdom\"", 27), $ConfSecAddr;
		foreach $one (@Global_Slave_Zone_Opts) {
		    printf F "\n                                  %s", $one;
		}
		if (exists($Slave_Zone_Opt{"$bootzone"})) {
		    foreach $one (split('\n', $Slave_Zone_Opt{"$bootzone"})) {
			printf F "\n                                  %s", $one;
		    }
		}
		printf F " };\n";
	    }
	}
	$spcl_file = "spcl-conf.sec";
	foreach $dir (@search_path) {
	    next unless -e "$dir/$spcl_file";
	    $spcl_file = "$dir/$spcl_file";
	    last;
	}
	if (-r $spcl_file) {
	    print F "\ninclude \"$spcl_file\";\n\n";
	}
	close(*F);
    }

    if (defined($BootSecSaveAddr)) {
	$bcname = "$Boot_Dir/boot.sec.save";
	unless (open(*F, '>', $bcname)) {
	    print STDERR "Unable to write `$bcname': $!\n",
			 "Check your -B and/or -z option argument(s).\n";
	    GIVE_UP();
	}
	print  F "\n";
	foreach $line (@Boot_Opts) {
	    printf F "%s\n", $line;
	}
	print  F "\ndirectory  $DB_Dir\n\n",
		 "cache      .\t\t\t\tdb.cache\n";
	if ($MakeLoopbackZone) {
	    print  F "primary    0.0.127.in-addr.arpa\t\tdb.127.0.0\n";
	}
	foreach $line (@Boot_Msgs) {
	    ($bootdom, $bootdb) = split(' ', $line, 2);
	    printf F "secondary  %s%s%s\n", TAB($bootdom, 29),
		     TAB($BootSecSaveAddr, 16), $bootdb;
	}
	$spcl_file = "spcl-boot.sec.save";
	foreach $dir (@search_path) {
	    next unless -e "$dir/$spcl_file";
	    $spcl_file = "$dir/$spcl_file";
	    last;
	}
	if (-r $spcl_file) {
	    unless (open(*ADD, '<', $spcl_file)) {
		print STDERR "Unable to read `$spcl_file': $!\n";
		GIVE_UP();
	    }
	    printf F "\n; ----- Begin contents of file `$spcl_file' -----\n\n";
	    while (<ADD>) {
		print F;
	    }
	    close(*ADD);
	    printf F "\n; ----- End of appended file `$spcl_file' -----\n\n";
	    if ($Verbose) {
		print STDOUT "File `$spcl_file' found and appended to ",
			     "`$bcname'.\n";
	    }
	}
	close(*F);
    }

    if (defined($ConfSecSaveAddr)) {
	$bcname = "$Boot_Dir/conf.sec.save";
	unless (open(*F, '>', $bcname)) {
	    print STDERR "Unable to write `$bcname': $!\n",
			 "Check your -B and/or -z option argument(s).\n";
	    GIVE_UP();
	}
	if ($Conf_Prefile) {
	    print F "\ninclude \"$Conf_Prefile\";\n";
	}
	if ($CustomLogging) {
	    if (@Conf_Logging) {
		print  F "\nlogging {\n";
		foreach $line (@Conf_Logging) {
		    printf F "\t%s\n", $line;
		}
		print  F "};\n\n";
	    } else {
		print  F "\nlogging {\n",
			 "\tcategory lame-servers { null; };\n",
			 "\tcategory cname { null; };\n",
			 "\tcategory security { default_syslog; };\n",
			 "};\n\n";
	    }
	}
	if ($CustomOptions) {
	    if (@Conf_Opts) {
		print F "\n" unless $CustomLogging;
		print F "options {\n",
			"\tdirectory \"$DB_Dir\";\n";
		foreach $line (@Conf_Opts) {
		    printf F "\t%s\n", $line;
		}
		print F "};\n\n";
	    }
	} else {
	    print F "\n" unless $CustomLogging;
	    print F "options {\n",
		    "\tdirectory \"$DB_Dir\";\n",
		    "};\n\n";
	}
	if ($NeedHints) {
	    if ($New_Fmt_Conffile) {
		print F "zone \".\" {\n\ttype hint;\n\tfile \"db.cache\";",
			"\n};\n";
	    } else {
		print F "zone \".\"\t\t\t{ type hint;\tfile \"db.cache\"; };\n";
	    }
	} elsif ($Conf_Prefile) {
	    print F "\n" unless $CustomLogging;
	}
	if ($MakeLoopbackZone) {
	    if ($New_Fmt_Conffile) {
		print F "zone \"0.0.127.in-addr.arpa\" {\n\ttype master;\n",
			"\tfile \"db.127.0.0\";\n};\n";
	    } else {
		print F "zone \"0.0.127.in-addr.arpa\"\t{ type master;",
			"\tfile \"db.127.0.0\"; };\n";
	    }
	}
	foreach $line (@Boot_Msgs) {
	    ($bootdom, $bootdb) = split(' ', $line, 2);
	    $bootzone = $bootdb;
	    $bootdb ~~ s/^db/bak/i;
	    if ($New_Fmt_Conffile) {
		$format = "zone \"%s\" {\n\ttype slave;\n\tfile \"%s\";\n"
			. "\tmasters { %s };";
		printf F $format, $bootdom, $bootdb, $ConfSecSaveAddr;
		foreach $one (@Global_Slave_Zone_Opts) {
		    printf F "\n\t%s", $one;
		}
		if (exists($Slave_Zone_Opt{"$bootzone"})) {
		    foreach $one (split('\n', $Slave_Zone_Opt{"$bootzone"})) {
			printf F "\n\t%s", $one;
		    }
		}
		printf F "\n};\n";
	    } else {
		printf F "zone %s{ type slave;\tfile %smasters { %s };",
			 TAB("\"$bootdom\"", 27), TAB("\"$bootdb\";", 19),
			 $ConfSecSaveAddr;
		foreach $one (@Global_Slave_Zone_Opts) {
		    printf F "\n                                  %s", $one;
		}
		if (exists($Slave_Zone_Opt{"$bootzone"})) {
		    foreach $one (split('\n', $Slave_Zone_Opt{"$bootzone"})) {
			printf F "\n                                  %s", $one;
		    }
		}
		printf F " };\n";
	    }
	}
	$spcl_file = "spcl-conf.sec.save";
	foreach $dir (@search_path) {
	    next unless -e "$dir/$spcl_file";
	    $spcl_file = "$dir/$spcl_file";
	    last;
	}
	if (-r $spcl_file) {
	    print F "\ninclude \"$spcl_file\";\n\n";
	}
	close(*F);
    }
    return;
}



sub DELEGATE_INFO {
    my ($addr, $addr_test, $check_temp, $date, $file, $fname, $glue_missing);
    my ($i, $in_zone, $ns, $one, $origin, $owner, $pid, $s, $search);
    my ($ttl, $zone);
    my (%glue, @db_search, @ns_need_glue);

    if (defined($Del_File)) {
	*STDFILE = *STDOUT;	# Limit STDERR to error and warning messages
    } else {
	*STDFILE = *STDERR;	# Status messages also go to STDERR unless -q
    }
    $Ttl = $Master_Ttl if $RFC_2308;		# RFC-2308 is true unless unset
    $ttl = ($Ttl) ? $Ttl : $DefTtl;		# via -o or GET_BIND_VERSION
    print STDFILE "Creating delegation...\n" if $Verbose;

    $check_temp = "$Debug_DIR/delegate_$Domain";
    open(*DELEGATE, '>', $check_temp)
	or die "Sorry, couldn't write `$check_temp': $!\n";
    foreach $i (@Make_SOA) {
	($fname, $file) = split(' ', $i, 2);
	if ($file eq "DOMAIN") {	# Tally up NS records, save in temp file
	    $zone = "$Domain.";
	} else {
	    ($zone = REVERSE($file)) ~~ s/DB//;
	    $zone .= "in-addr.arpa.";
	}
	$in_zone = $zone;		# For ID'ing in-zone NS RRs needing glue
	$in_zone ~~ s/[.]/\\./g;

	foreach $s (@Full_Servers) {
	    printf DELEGATE "%s%s\tNS\t%s\n",
			    ($zone eq $Owner_Field ?? "\t\t\t\t"
						   !! TAB($zone, 32)),
			    $ttl, $s;
	    $Owner_Field = $zone;
	    if ($s ~~ /$in_zone$/) {
		push(@ns_need_glue, $s);
	    }
	}
	if (exists($Partial_Servers{$fname})) {
	    foreach $s (split(' ', $Partial_Servers{$fname})) {
		printf DELEGATE "%s%s\tNS\t%s\n",
			        ($zone eq $Owner_Field ?? "\t\t\t\t"
						       !! TAB($zone, 32)),
				$ttl, $s;
		$Owner_Field = $zone;
		if ($s ~~ /$in_zone$/) {
		    push(@ns_need_glue, $s);
		}
	    }
	} elsif (!@Full_Servers) {
	    #
	    # Add name server in MNAME field of SOA record if missing -s/-S
	    #
	    printf DELEGATE "%s%s\tNS\t%s\n",
			    ($zone eq $Owner_Field ?? "\t\t\t\t"
						   !! TAB($zone, 32)),
			    $ttl, $RespHost;
	    $Owner_Field = $zone;
	    if ($RespHost ~~ /$in_zone$/) {
		push(@ns_need_glue, $RespHost);
	    }
	}
	print DELEGATE "\n";
    }
    if (@ns_need_glue) {		  # Do we need to find glue?
	push(@db_search, "$Domainfile");  # If yes, start with forward zone (-d)
	$origin = "$Domain.";

	while ($search = shift(@db_search)) {
	    unless (open(*GLUE, '<', $search)) {
		print STDERR "Couldn't open `$search': $!\nHave you run h2n ",
			     "yet?  Does current directory contain db files?\n";
		GIVE_UP();
	    }
	    $owner = "";
	    while (<GLUE>) {
		next if /^[;@]/ || /^$/;
		if (/^\$TTL\s+(\S+)/) {		 # get default TTL if necessary
		    $Ttl = $1 unless $Master_Ttl;
		} elsif (/^\$INCLUDE\s+(\S+)/) { # other files to look through
		    push(@db_search, $1);
		} elsif (/^\$ORIGIN\s+(\S+)/) {	 # origin could change
		    $origin = lc($1);
		}
		next if /^\$/;			 # directive processing complete
		if (/^(\S+)/) {
		    #
		    # Get current owner name and make it a FQDN.
		    #
		    $owner = lc($1);
		    $owner .= ".$origin" unless $owner ~~ /[^\\][.]$/;
		}
		if (/^(?:\S+)?\s+(\d+|(\d+[wdhms])+)?\s*    # Owner, TTL
		    (?:IN)?\s*A\s+([.\d]+)/ix) {	    # class, type, RDATA
		    # Matched on an A record.
		    $addr = $3;
		    if ($1) {				    # Grab TTL
			$ttl = $1;
		    } else {
			$ttl = ($Ttl) ?? $Ttl !! $DefTtl;
		    }
		    ($addr_test = $addr) ~~ s/[.]/\\./g;
		    foreach $one (@ns_need_glue) {
			next unless $owner eq $one;
			if (exists($glue{$one})
			    && $glue{$one} ~~ / $addr_test:/) {
			    if ($Verbose) {
				print STDERR "Hmm, found a duplicate glue IP ",
					     "for `$one [$addr].'\nIgnored ",
					     "for now but do fix this at the ",
					     "earliest opportunity.\n";
			    }
			} else {
			    #
			    # Tally up glue IPs w/TTLs
			    #
			    $glue{$one} .= " $addr:$ttl";
			}
		    }
		}
	    }
	    close(*GLUE);
	}

	foreach $one (@ns_need_glue) {
	    next if defined($glue{$one});
	    print STDERR "No glue Address record found for `$one'\n";
	    $glue_missing = 1;
	}
	if ($glue_missing) {
	    print STDERR "Check for valid -s/-S options, then make sure the ",
			 "server names exist\nin `$Domainfile' (or in a file ",
			 "referenced by an \$INCLUDE directive).\n",
			 "I give up... can't continue without glue.\n";
	    close(*DELEGATE);
	    unlink "$check_temp" unless $Debug;
	    exit(2);
	}

	$Owner_Field = "";
	foreach $ns (keys %glue) {			# Add glue A records
	    foreach $one (split(' ', $glue{$ns})) {
		($addr, $ttl) = split(/:/, $one, 2);
		printf DELEGATE "%s%s\tA\t%s\n",
				($ns eq $Owner_Field ?? "\t\t\t\t"
						     !! TAB($ns, 32)),
				$ttl, $addr;
		$Owner_Field = $ns;
	    }
	}
	print DELEGATE "\n";
    }
    close(*DELEGATE);
    print STDFILE "Checking name servers...\n" if $Verbose;
    $date = `date`; chop $date;
    if (defined($Del_File)) {
	unless (open(*DELFILE, '>', $Del_File)) {
	    print STDERR "Sorry, couldn't open `$Del_File': $!\n";
	    GIVE_UP();
	}
    } else {
	open(*DELFILE, ">&STDOUT");
    }
    select(*DELFILE); local $| = 1;	# Make this FD non-blocking so output
					# isn't duplicated due to fork.
    printf DELFILE "\n;\n; Delegation information for %s\n", $Domain;
    printf DELFILE "; Generated by %s on %s, %s (h2n v$VERSION)\n",
		   (getpwuid($<))[0], hostname(), $date;
    printf DELFILE "; Domain's master name server is `%s'\n", $Host;
    printf DELFILE "; which is running BIND version %s\n;\n", $BIND_Version;
    if ($BIND_Ver_Msg) {
	print DELFILE "; Warning: this version of BIND may be vulnerable ",
		      "to the following bug(s):\n";
	$BIND_Ver_Msg = "; $BIND_Ver_Msg";
	$BIND_Ver_Msg ~~ s/^ ($BIND_Bug_Titles)/;  $1/gmo;
	$BIND_Ver_Msg ~~ s/ See /; See /;
	$BIND_Ver_Msg ~~ s/     </;     </g;
	print DELFILE "$BIND_Ver_Msg\n;\n";
    }
    $pid = open(*CHECKIT, '-|');	# Causes fork.  Usual parent/child
					# processing follows...
    if ($pid) {
	while (<CHECKIT>) { printf DELFILE "; %s", $_; }
	close(*CHECKIT);
    } else {
	$s = 0;
	unless (exec("$Check_Del -f $check_temp")) {
	    print "; Can't run `$Check_Del', got it installed?\n";
	    $s = 1;
	}
	exit($s);
    }
    print DELFILE ";\n\n";
    unless (open(*DELEGATE, '<', $check_temp)) {
	print STDERR "Hmm... file `$check_temp' disappeared on me!: $!\n";
	GIVE_UP();
    }
    while (<DELEGATE>) { print DELFILE; }
    close(*DELEGATE);
    close(*DELFILE);
    unlink "$check_temp" unless $Debug;
    if (defined($Del_File) && $Verbose) {
	print STDFILE "Delegation saved in file `$Del_File'\n";
    }
    return;
}
