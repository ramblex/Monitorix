#
# Monitorix - A lightweight system monitoring tool.
#
# Copyright (C) 2005-2015 by Jordi Sanfeliu <jordi@fibranet.cat>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
#

package dag;

use strict;
use warnings;
use Monitorix;
use RRDs;
use POSIX qw(strftime);
use Exporter 'import';
our @EXPORT = qw(dag_init dag_update dag_cgi);

sub dag_init {
	my $myself = (caller(0))[3];
	my ($package, $config, $debug) = @_;
	my $rrd = $config->{base_lib} . $package . ".rrd";
	my $dag = $config->{dag};

	my $info;
	my @ds;
	my @rra;
	my @tmp;
	my $n;

	my @average;
	my @min;
	my @max;
	my @last;

	if(-e $rrd) {
		$info = RRDs::info($rrd);
		for my $key (keys %$info) {
			if(index($key, 'rra[') == 0) {
				if(index($key, '.rows') != -1) {
					push(@rra, substr($key, 4, index($key, ']') - 4));
				}
			}
		}
		if(scalar(@rra) < 12 + (4 * $config->{max_historic_years})) {
			logger("$myself: Detected size mismatch between 'max_historic_years' (" . $config->{max_historic_years} . ") and $rrd (" . ((scalar(@rra) -12) / 4) . "). Resizing it accordingly. All historical data will be lost. Backup file created.");
			rename($rrd, "$rrd.bak");
		}
	}

	if(!(-e $rrd)) {
		logger("Creating '$rrd' file.");
		for($n = 1; $n <= $config->{max_historic_years}; $n++) {
			push(@average, "RRA:AVERAGE:0.5:1440:" . (365 * $n));
			push(@min, "RRA:MIN:0.5:1440:" . (365 * $n));
			push(@max, "RRA:MAX:0.5:1440:" . (365 * $n));
			push(@last, "RRA:LAST:0.5:1440:" . (365 * $n));
		}

        my $numcards = 0;
        if (open(IN, "lspci | grep 'Endace' |")) {
            my @cardlist = <IN>;
            $numcards = scalar(@cardlist);
            close(IN);
        } else {
            logger("$myself: WARNING: unable to get number of DAG cards");
        }

        for ($n = 0; $n < $numcards; $n++) {
            push(@tmp, "DS:dag_temp" . $n . ":GAUGE:120:0:100");
        }

		eval {
			RRDs::create($rrd,
				"--step=60",
                @tmp,
				"RRA:AVERAGE:0.5:1:1440",
				"RRA:AVERAGE:0.5:30:336",
				"RRA:AVERAGE:0.5:60:744",
				@average,
				"RRA:MIN:0.5:1:1440",
				"RRA:MIN:0.5:30:336",
				"RRA:MIN:0.5:60:744",
				@min,
				"RRA:MAX:0.5:1:1440",
				"RRA:MAX:0.5:30:336",
				"RRA:MAX:0.5:60:744",
				@max,
				"RRA:LAST:0.5:1:1440",
				"RRA:LAST:0.5:30:336",
				"RRA:LAST:0.5:60:744",
				@last,
			);
		};
		my $err = RRDs::error;
		if($@ || $err) {
			logger("$@") unless !$@;
			if($err) {
				logger("ERROR: while creating $rrd: $err");
				if($err eq "RRDs::error") {
					logger("... is the RRDtool Perl package installed?");
				}
			}
			return;
		}
	}

	push(@{$config->{func_update}}, $package);
	logger("$myself: Ok") if $debug;
}

sub dag_update {
	my $myself = (caller(0))[3];
	my ($package, $config, $debug) = @_;
	my $rrd = $config->{base_lib} . $package . ".rrd";
	my $dag = $config->{dag};

	my $str;
	my $rrdata = "N";

    my $numcards = 0;
    if (open(IN, "lspci | grep 'Endace' |")) {
        my @cardlist = <IN>;
        $numcards = scalar(@cardlist);
        close(IN);
    } else {
        logger("$myself: WARNING: unable to get number of DAG cards");
    }

    my @cards;
    my $n;
    for ($n = 0; $n < $numcards; $n++) {
        my @data;
        if (open(IN, "/usr/local/bin/dagconfig -m -d$n |")) {
            @data = <IN>;
            close(IN);
        } else {
            logger("$myself: WARNING: unable to execute '/usr/local/bin/dagconfig' command.");
        }

        $str = $data[1];
        chomp($str);
        $str =~ s/^\s+|\s+$//g;

        $rrdata .= ":" . $str;
    }

	RRDs::update($rrd, $rrdata);
	logger("$myself: $rrdata");
	my $err = RRDs::error;
	logger("ERROR: while updating $rrd: $err") if $err;
}

sub dag_cgi {
	my ($package, $config, $cgi) = @_;

	my $dag = $config->{dag};
	my @rigid = split(',', ($dag->{rigid} || ""));
	my @limit = split(',', ($dag->{limit} || ""));
	my $tf = $cgi->{tf};
	my $colors = $cgi->{colors};
	my $graph = $cgi->{graph};
	my $silent = $cgi->{silent};
	my $zoom = "--zoom=" . $config->{global_zoom};
	my %rrd = (
		'new' => \&RRDs::graphv,
		'old' => \&RRDs::graph,
	);
	my $version = "new";
	my $pic;
	my $picz;
	my $picz_width;
	my $picz_height;

	my $u = "";
	my $width;
	my $height;
	my @riglim;
	my @PNG;
	my @PNGz;
	my @tmp;
	my @tmpz;
	my @CDEF;
	my $n;
	my $n2;
	my $str;
	my $err;
	my @LC = (
		"#4444EE",
		"#EEEE44",
		"#44EEEE",
		"#EE44EE",
		"#888888",
		"#E29136",
		"#44EE44",
		"#448844",
		"#EE4444",
	);

	$version = "old" if $RRDs::VERSION < 1.3;
	my $rrd = $config->{base_lib} . $package . ".rrd";
	my $title = $config->{graph_title}->{$package};
	my $PNG_DIR = $config->{base_dir} . "/" . $config->{imgs_dir};

	$title = !$silent ? $title : "";

	# graph mode
	#
	if($silent eq "yes" || $silent eq "imagetag") {
		$colors->{fg_color} = "#000000";  # visible color for text mode
		$u = "_";
	}
	if($silent eq "imagetagbig") {
		$colors->{fg_color} = "#000000";  # visible color for text mode
		$u = "";
	}

    my $tempPNG = $u . $package . "1." . $tf->{when} . ".png";
    unlink("$PNG_DIR" . $tempPNG);

    my $tempPNGz = $u . $package . "1z." . $tf->{when} . ".png";
    unlink("$PNG_DIR" . $tempPNGz);

	if($title) {
		main::graph_header($title, 1);
	}

	if($title) {
		print("    <tr>\n");
		print("    <td valign='bottom' bgcolor='$colors->{title_bg_color}'>\n");
	}

    my $numcards = 0;
    if (open(IN, "lspci | grep 'Endace' |")) {
        my @cardlist = <IN>;
        $numcards = scalar(@cardlist);
        close(IN);
    } else {
        print("ERROR: unable to get number of DAG cards");
    }

    my @cards;
    for ($n = 0; $n < $numcards; $n++) {
        push(@cards, "DEF:dag$n=$rrd:dag_temp$n:AVERAGE");
        push(@cards, "LINE1:dag$n".$LC[$n].":Card $n Temperature");
    }

	@riglim = @{setup_riglim($rigid[0], $limit[0])};
    ($width, $height) = split('x', $config->{graph_size}->{medium});
    $pic = $rrd{$version}->("$PNG_DIR" . "$tempPNG",
        "--title=$config->{graphs}->{_dag1}  ($tf->{nwhen}$tf->{twhen})",
        "--start=-$tf->{nwhen}$tf->{twhen}",
        "--imgformat=PNG",
        "--vertical-label=Degrees (C)",
        "--width=$width",
        "--height=$height",
        @riglim,
        $zoom,
        @{$cgi->{version12}},
        @{$colors->{graph_colors}},
        @cards);
    $err = RRDs::error;
    print("ERROR: while graphing $PNG_DIR" . "$tempPNG: $err\n") if $err;

    if(lc($config->{enable_zoom}) eq "y") {
        ($width, $height) = split('x', $config->{graph_size}->{zoom});
        $picz = $rrd{$version}->("$PNG_DIR" . "$tempPNGz",
            "--title=$config->{graphs}->{_dag1}  ($tf->{nwhen}$tf->{twhen})",
            "--start=-$tf->{nwhen}$tf->{twhen}",
            "--imgformat=PNG",
            "--vertical-label=Degrees (C)",
            "--width=$width",
            "--height=$height",
            @riglim,
            $zoom,
            @{$cgi->{version12}},
            @{$colors->{graph_colors}},
            @cards);
        $err = RRDs::error;
        print("ERROR: while graphing $PNG_DIR" . "$tempPNGz: $err\n") if $err;
    }

    if($title || ($silent =~ /imagetag/ && $graph =~ /dag1/)) {
        if(lc($config->{enable_zoom}) eq "y") {
            if(lc($config->{disable_javascript_void}) eq "y") {
                print("      <a href=\"" . $config->{url} . "/" . $config->{imgs_dir} . $tempPNGz . "\"><img src='" . $config->{url} . "/" . $config->{imgs_dir} . $tempPNG . "' border='0'></a>\n");
            } else {
                if($version eq "new") {
                    $picz_width = $picz->{image_width} * $config->{global_zoom};
                    $picz_height = $picz->{image_height} * $config->{global_zoom};
                } else {
                    $picz_width = $width + 115;
                    $picz_height = $height + 100;
                }
                print("      <a href=\"javascript:void(window.open('" . $config->{url} . "/" . $config->{imgs_dir} . $tempPNGz . "','','width=" . $picz_width . ",height=" . $picz_height . ",scrollbars=0,resizable=0'))\"><img src='" . $config->{url} . "/" . $config->{imgs_dir} . $tempPNG . "' border='0'></a>\n");
            }
        } else {
            print("      <img src='" . $config->{url} . "/" . $config->{imgs_dir} . $tempPNG . "'>\n");
        }
    }

    if($title) {
        print("    </td>\n");
    }

    if($title) {
        print("    </tr>\n");
    }

	$n = 0;
	if($title) {
		main::graph_footer();
	}
	print("  <br>\n");
	return;
}

1;
