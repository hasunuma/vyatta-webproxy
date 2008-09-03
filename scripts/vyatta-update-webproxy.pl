#!/usr/bin/perl
#
# Module: vyatta-update-webproxy.pl
# 
# **** License ****
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 as
# published by the Free Software Foundation.
# 
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
# 
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2008 Vyatta, Inc.
# All Rights Reserved.
# 
# Author: Stig Thormodsrud
# Date: August 2008
# Description: Script to configure webproxy (squid and squidguard).
# 
# **** End License ****
#

use Getopt::Long;
use POSIX;

use lib "/opt/vyatta/share/perl5/";
use VyattaConfig;

use warnings;
use strict;

my $squid_conf      = '/etc/squid3/squid.conf';
my $squid_log       = '/var/log/squid3/access.log';
my $squid_cache_dir = '/var/spool/squid3';
my $squid_init      = '/etc/init.d/squid3';
my $squid_def_fs    = 'ufs';
my $squid_def_port  = 3128;

my $squidguard_conf          = '/etc/squid/squidGuard.conf';
my $squidguard_log           = '/var/log/squid';
my $squidguard_blacklist_log = "$squidguard_log/blacklist.log";
my $squidguard_blacklist_db  = '/var/lib/squidguard/db';
my $squidguard_redirect_def  = "http://www.google.com";
my $squidguard_enabled       = 0;

my %config_ipaddrs = ();


sub numerically { $a <=> $b; }

sub squid_restart {
    system("$squid_init restart");
}

sub squid_stop {
    system("$squid_init stop");
}

sub squid_get_constants {
    my $output;
    
    my $date = `date`; chomp $date;
    $output  = "#\n# autogenerated by vyatta-update-webproxy.pl on $date\n#\n";

    $output .= "access_log $squid_log squid\n\n";

    $output .= "acl manager proto cache_object\n";
    $output .= "acl localhost src 127.0.0.1/32\n";
    $output .= "acl to_localhost dst 127.0.0.0/8\n";
    $output .= "acl net src 0.0.0.0/0\n";
    $output .= "acl SSL_ports port 443\n";
    $output .= "acl Safe_ports port 80          # http\n";
    $output .= "acl Safe_ports port 21          # ftp\n";
    $output .= "acl Safe_ports port 443         # https\n";
    $output .= "acl Safe_ports port 70          # gopher\n";
    $output .= "acl Safe_ports port 210         # wais\n";
    $output .= "acl Safe_ports port 1025-65535  # unregistered ports\n";
    $output .= "acl Safe_ports port 280         # http-mgmt\n";
    $output .= "acl Safe_ports port 488         # gss-http\n";
    $output .= "acl Safe_ports port 591         # filemaker\n";
    $output .= "acl Safe_ports port 777         # multiling http\n";
    $output .= "acl CONNECT method CONNECT\n\n";
    
    $output .= "http_access allow manager localhost\n";
    $output .= "http_access deny manager\n";
    $output .= "http_access deny !Safe_ports\n";
    $output .= "http_access deny CONNECT !SSL_ports\n";
    $output .= "http_access allow localhost\n";
    $output .= "http_access allow net\n";
    $output .= "http_access deny all\n\n";

    return $output;
}

sub squid_validate_conf {
    my $config = new VyattaConfig;

    #
    # Need to validate the config before issuing any iptables 
    # commands.
    #
    $config->setLevel("service webproxy");
    my $cache_size = $config->returnValue("cache-size");
    if (! defined $cache_size) {
	print "Must define cache-size\n";
	exit 1;
    }

    $config->setLevel("service webproxy listening-address");
    my @ipaddrs = $config->listNodes();
    if (scalar(@ipaddrs) <= 0) {
	print "Must define at least 1 listening-address\n";
	exit 1;
    }

    foreach my $ipaddr (@ipaddrs) {
	if (!defined $config_ipaddrs{$ipaddr}) {
	    print "listing-address [$ipaddr] is not a configured address\n";
	    exit 1;
	}
    }
}

sub squid_get_values {
    my $output = '';
    my $config = new VyattaConfig;

    $config->setLevel("service webproxy");
    my $def_port = $config->returnValue("default-port");
    $def_port = $squid_def_port if ! defined $def_port;

    my $cache_size = $config->returnValue("cache-size");
    $cache_size = 100 if ! defined $cache_size;
    if ($cache_size > 0) {
	$output  = "cache_dir $squid_def_fs $squid_cache_dir ";
        $output .= "$cache_size 16 256\n\n";
    } else {
	# disable caching
	$output  = "cache_dir null /null\n\n";
    }

    $config->setLevel("service webproxy listening-address");
    my %ipaddrs_status = $config->listNodeStatus();
    my @ipaddrs = sort numerically keys %ipaddrs_status;
    foreach my $ipaddr (@ipaddrs) {
	my $status = $ipaddrs_status{$ipaddr};
	#print "$ipaddr = [$status]\n";

	my $o_port = $config->returnOrigValue("$ipaddr port");	
	my $n_port = $config->returnValue("$ipaddr port");	
	$o_port = $def_port if ! defined $o_port;	
	$n_port = $def_port if ! defined $n_port;	

	my $o_dt = $config->existsOrig("$ipaddr disable-transparent");
	my $n_dt = $config->exists("$ipaddr disable-transparent");
	my $transparent = "transparent";
	$transparent = "" if $n_dt;
	$output .= "http_port $ipaddr:$n_port $transparent\n";

	my $intf = $config_ipaddrs{$ipaddr};

	#
	# handle NAT rule for transparent
	#
        my $A_or_D = undef;
	if ($status eq "added" and !defined $n_dt) {
	    $A_or_D = 'A';
	} elsif ($status eq "deleted") {
	    $A_or_D = 'D';
	} elsif ($status eq "changed") {
	    $o_dt = 0 if !defined $o_dt;
	    $n_dt = 0 if !defined $n_dt;
	    if ($o_dt ne $n_dt) {
		if ($n_dt) {
		    $A_or_D = 'D';
		} else {
		    $A_or_D = 'A';
		}
	    }
	    #
	    #handle port # change
	    #
	    if ($o_port ne $n_port and !$o_dt) {
		my $cmd = "sudo iptables -t nat -D PREROUTING -i $intf ";
		$cmd   .= "-p tcp --dport 80 -j REDIRECT --to-port $o_port";
		#print "[$cmd]\n";
		my $rc = system($cmd);
		if ($rc) {
		    print "Error adding port redirect [$!]\n";
		}		
		if (!$n_dt) {
		    $A_or_D = 'A';		    
	        } else {
		    $A_or_D = undef;
		}
	    }
	}
	if (defined $A_or_D) {
	    my $cmd = "sudo iptables -t nat -$A_or_D PREROUTING -i $intf ";
	    $cmd   .= "-p tcp --dport 80 -j REDIRECT --to-port $n_port";
	    #print "[$cmd]\n";
	    my $rc = system($cmd);
	    if ($rc) {
		print "Error adding port redirect [$!]\n";
	    }
	} 
    }
    $output .= "\n";

    #
    # check if squidguard is configured
    #
    $config->setLevel("service webproxy url-filtering");
    if ($config->exists("squidguard")) {
	$squidguard_enabled = 1;
	$output .= "redirect_program /usr/bin/squidGuard -c $squidguard_conf\n";
	$output .= "redirect_children 8\n";
	$output .= "redirector_bypass on\n\n";
    }
    return $output;
}

sub squidguard_get_constants {
    my $output;
    my $date = `date`; chomp $date;
    $output  = "#\n# autogenerated by vyatta-update-webproxy.pl on $date\n#\n";

    $output  = "dbhome /var/lib/squidguard/db\n";
    $output .= "logdir /var/log/squid\n\n";

    return $output;
}

sub squidguard_get_blacklists {
    my ($dir) = shift;

    my @blacklists = ();
    opendir(DIR, $dir) || die "can't opendir $dir: $!";
    my @dirs = readdir(DIR);
    closedir DIR;

    foreach my $file (@dirs) {
	next if $file eq '.';
	next if $file eq '..';
	if (-d "$dir/$file") {
	    push @blacklists, $file;
	}
    }
    return @blacklists;
}

sub squidguard_get_blacklist_domains_urls_exps {
    my ($list) = shift;

    my $dir = $squidguard_blacklist_db;
    my ($domains, $urls, $exps) = undef;
    $domains = "$list/domains"     if -f "$dir/$list/domains";
    $urls    = "$list/urls"        if -f "$dir/$list/urls";
    $exps    = "$list/expressions" if -f "$dir/$list/expressions";
    return ($domains, $urls, $exps);
}

sub squidguard_get_values {
    my $output = "";
    my $config = new VyattaConfig;

    $config->setLevel("service webproxy url-filtering squidguard block-site");
    my @block_sites = $config->returnValues();

    $config->setLevel("service webproxy url-filtering squidguard log");
    my @log_category = $config->returnValues();
    my %is_logged = map { $_ => 1 } @log_category;    

    my @blacklists   = squidguard_get_blacklists($squidguard_blacklist_db);
    my %is_blacklist = map { $_ => 1 } @blacklists;

    if (scalar(@block_sites) <= 0) {
	#
	# add all blacklist categories
	#
	if (scalar(@blacklists) <= 0) {
	    print "No blacklists found\n";
	    exit 1;
	}
	@block_sites = @blacklists;
    }

    my $acl_block = "";
    foreach my $site (@block_sites) {
	if (! defined $is_blacklist{$site}) {
	    print "Unknown blacklist category [$site]\n";
	    exit 1;
	}
	my ($domains, $urls, $exps) = 
	    squidguard_get_blacklist_domains_urls_exps($site);
	$output    .= "dest $site {\n";
	$output    .= "\tdomainlist     $domains\n" if defined $domains;
	$output    .= "\turllist        $urls\n"    if defined $urls;
	$output    .= "\texpressionlist $exps\n"    if defined $exps;
	if (defined $is_logged{all} or defined $is_logged{$site}) {
	    $output    .= "\tlog            $squidguard_blacklist_log\n";
	}
	$output    .= "}\n\n";
	$acl_block .= "!$site ";
    }

    $output .= "acl {\n";
    $output .= "\tdefault {\n";
    $output .= "\t\tpass !in-addr $acl_block all\n";

    $config->setLevel("service webproxy url-filtering squidguard");
    my $redirect_url = $config->returnValue("redirect-url");
    $redirect_url = $squidguard_redirect_def if ! defined $redirect_url;

    $output .= "\t\tredirect 302:$redirect_url\n\t}\n}\n";

    return $output;
}

sub webproxy_write_file {
    my ($file, $config) = @_;

    open(my $fh, '>', $file) || die "Couldn't open $file - $!";
    print $fh $config;
    close $fh;
}


#
# main
#
my $update_webproxy;
my $stop_webproxy;

GetOptions("update!" => \$update_webproxy,
           "stop!"   => \$stop_webproxy);

#
# make a hash of ipaddrs => interface
#
my @lines = `ip addr show | grep 'inet '`;
chomp @lines;
foreach my $line (@lines) {
    if ($line =~ /inet\s+([0-9.]+)\/.*\s(\w+)$/) {
	$config_ipaddrs{$1} = $2;
    }
}

if (defined $update_webproxy) { 
    my $config;

    squid_validate_conf();
    $config  = squid_get_constants();
    $config .= squid_get_values();
    webproxy_write_file($squid_conf, $config);
    if ($squidguard_enabled) {
	my $config2;
	$config2  = squidguard_get_constants();
	$config2 .= squidguard_get_values();
	webproxy_write_file($squidguard_conf, $config2);
    }
    squid_restart();
}

if (defined $stop_webproxy) {
    #
    # Need to call squid_get_values() to delete the NAT rules
    #
    squid_get_values();
    squid_stop();
}

exit 0;

# end of file
