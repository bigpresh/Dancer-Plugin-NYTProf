package Dancer::Plugin::NYTProf;

use strict;
use Dancer::Plugin;
use base 'Dancer::Plugin';
use Dancer qw(:syntax);
use Dancer::FileUtils;
use File::stat;
use File::Temp;
use File::Which;

our $VERSION = '0.20';


=head1 NAME

Dancer::Plugin::NYTProf - easy Devel::NYTProf profiling for Dancer apps

=head1 DESCRIPTION

A plugin to provide easy profiling for Dancer applications, using the venerable
L<Devel::NYTProf>.

By simply loading this plugin, you'll have the detailed, helpful profiling
provided by Devel::NYTProf.

Each individual request to your app is profiled.  Going to the URL
C</nytprof> in your app will present a list of profiles; selecting one will
invoke C<nytprofhtml> to generate the HTML reports (unless they already exist),
then serve them up.

B<WARNING> This is an early version of this code which is still in development.
In general this isn't a plugin I'd advise to use in a production environment
anyway, but in particular, it uses C<system> to execute C<nytprofhtml>, and I
need to very carefully re-examine the code to make sure that user input cannot
be used to nefarious effect.  You are recommended to only use this in your
development environment.

=head1 CONFIGURATION

The plugin will work by default without any configuration required - it will
default to writing profiling data into a dir named C<profdir> within your Dancer
application's C<appdir>, present profiling output at C</nytprof> (not yet
configurable), and profile all requests.

Below is an example of the options you can configure:

    plugins:
        NYTProf:
            profdir: '/tmp/profiledata'
            nytprofhtmlpath: '/usr/local/bin/nytprofhtml'

More configuration (such as the URL at which output is produced, and options to
control which requests get profiled) will be added in a future version.  (If
there's something you'd like to see soon, do contact me and let me know - it'll
likely get done a lot quicker then!)

=cut


my $setting = plugin_setting;

# Work out where nytprof_html is, or die with a sensible error
my $nytprofhtml_path = File::Which::which(
    $setting->{nytprofhtml_path} || 'nytprofhtml'
) or die "Could not find nytprofhtml script.  Ensure it's in your path, "
       . "or set the nytprofhtml_path option in your config.";


# Need to load Devel::NYTProf at runtime after setting env var, as it will
# insist on creating an nytprof.out file immediately - even if we tell it not to
# start profiling.
# Dirty workaround: get a temp file, then let Devel::NYTProf use that, with
# addpid enabled so that it will append the PID too (so the filename won't
# exist), load Devel::NYTProf, then unlink the file.
# This is dirty, hacky shit that needs to die, but should make things work for
# now.
my $tempfh = File::Temp->new;
my $file = $tempfh->filename;
$tempfh = undef; # let the file get deleted
$ENV{NYTPROF} = "start=no:file=$file";
require Devel::NYTProf;
unlink $file;

hook 'before' => sub {
    my $path = request->path;

    # Make sure that the directories we need to put profiling data in exist,
    # first:
    $setting->{profdir} ||= Dancer::FileUtils::path(
        setting('appdir'), 'nytprof'
    );
    if (! -d $setting->{profdir}) {
        mkdir $setting->{profdir}
            or die "$setting->{profdir} does not exist and cannot create - $!";
    }
    if (!-d Dancer::FileUtils::path($setting->{profdir}, 'html')) {
        mkdir Dancer::FileUtils::path($setting->{profdir}, 'html')
            or die "Could not create html dir.";
    }

    # Go no further if this request was to view profiling output:
    return if $path =~ m{^/nytprof};
    return if $path =~ m{^/nytprof};

    # Now, fix up the path into something we can use for a filename:
    $path =~ s{^/}{};
    $path =~ s{/}{_s_}g;
    $path =~ s{[^a-z0-9]}{_}gi;

    # Start profiling, and let the request continue
    DB::enable_profile(
        Dancer::FileUtils::path($setting->{profdir}, "nytprof.out.$path.$$")
    );
};

hook 'after' => sub {
    DB::disable_profile();
    DB::finish_profile();
};

get '/nytprof' => sub {
    opendir my $dirh, $setting->{profdir}
        or die "Unable to open profiles dir $setting->{profdir} - $!";
    my @files = grep { /^nytprof\.out/ } readdir $dirh;
    closedir $dirh;

    # HTML + CSS here is a bit ugly, but I want this to be usable as a
    # single-file plugin that Just Works, without needing to copy over templates
    # / CSS etc.
    my $html = <<LISTSTART;
<html><head><title>NYTProf profile run list</title>
<style>
* { font-family: Verdana, Arial, Helvetica, sans-serif; }
</style>
</head>
<body>
<h1>Profile run list</h1>
<p>Select a profile run output from the list to view the HTML reports as
produced by <tt>Devel::NYTProf</tt>.</p>

<ul>
LISTSTART

    for my $file (@files) {
        my $fullfilepath = Dancer::FileUtils::path($setting->{profdir}, $file);
        my $label = $file;
        $label =~ s{nytprof\.out\.}{};
        $label =~ s{_s_}{/}g;
        $label =~ s{\.(\d+)$}{};
        my $pid = $1;  # refactor this crap
        my $created = scalar localtime( (stat $fullfilepath)->ctime );
        $html .= qq{<li><a href="/nytprof/$file">$label</a>}
               . qq{ (PID $pid, $created)</li>};
    }

    $html .= <<LISTEND;
</ul>

<p>Generated by <a href="http://github.com/bigpresh/Dancer-Plugin-NYTProf">
Dancer::Plugin::NYTProf</a> v$VERSION</p>
</body>
</html>
LISTEND

    return $html;
};


# Serve up HTML reports
get '/nytprof/html/**' => sub {
    my ($path) = splat;
    send_file Dancer::FileUtils::path(
        $setting->{profdir}, 'html', map { _safe_filename($_) } @$path
    ), system_path => 1;
};

get '/nytprof/:filename' => sub {

    my $profiledata = Dancer::FileUtils::path(
        $setting->{profdir}, _safe_filename(param('filename'))
    );

    if (!-f $profiledata) {
        send_error 'not_found';
        return "No such profile run found.";
    }
    
    # See if we already have the HTML for this run stored; if not, invoke
    # nytprofhtml to generate it

    # Right, do we already have generated HTML for this one?  If so, use it
    my $htmldir = Dancer::FileUtils::path(
        $setting->{profdir}, 'html', _safe_filename(param('filename'))
    );
    if (! -f Dancer::FileUtils::path($htmldir, 'index.html')) {
        # TODO: scrutinise this very carefully to make sure it's not
        # exploitable
        system($nytprofhtml_path, "--file=$profiledata", "--out=$htmldir");

        if ($? == -1) {
            die "'$nytprofhtml_path' failed to execute: $!";
        } elsif ($? & 127) {
            die sprintf "'%s' died with signal %d, %s coredump",
                $nytprofhtml_path,,
                ($? & 127), 
                ($? & 128) ? 'with' : 'without';
        } else {
            die sprintf "'%s' exited with value %d", 
                $nytprofhtml_path, $? >> 8;
        }
    }

    # Redirect off to view it:
    return redirect '/nytprof/html/' 
        . param('filename') . '/index.html';

};


# Rudimentary security - remove any directory traversal or poison null
# attempts.  We're dealing with user input here, and if they're a sneaky
# bastard, they could convince us to send a file we shouldn't, or have
# nytprofhtml write its output to somewhere it shouldn't.  We don't want that.
sub _safe_filename {
    my $filename = shift;
    $filename =~ s/\\//g;
    $filename =~ s/\0//g;
    $filename =~ s/\.\.//g;
    $filename =~ s/[\/]//g;
    return $filename;
}

=head1 AUTHOR

David Precious, C<< <davidp at preshweb.co.uk> >>


=head1 ACKNOWLEDGEMENTS

Stefan Hornburg (racke)

Neil Hooey (nhooey)


=head1 BUGS

Please report any bugs or feature requests at
L<http://github.com/bigpresh/Dancer-Plugin-NYTProf/issues>.

=head1 CONTRIBUTING

This module is developed on GitHub:

L<http://github.com/bigpresh/Dancer-Plugin-NYTProf>

Bug reports, suggestions and pull requests all welcomed!

=head1 SEE ALSO

L<Dancer>

L<Devel::NYTProf>

L<Plack::Middleware::Debug::Profiler::NYTProf>


=head1 LICENSE AND COPYRIGHT

Copyright 2011 David Precious.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.


=cut

1; # End of Dancer::Plugin::NYTProf
