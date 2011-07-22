package Dancer::Plugin::NYTProf;

#use warnings;
use strict;
use Dancer::Plugin;
use base 'Dancer::Plugin';
use Devel::NYTProf;
use Dancer qw(:syntax);
use Dancer::FileUtils;


our $VERSION = '0.01';


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

=cut


# Find out where our profiling data is going, and create directories if needed:
my $setting = plugin_setting;
$setting->{profdir} ||= Dancer::FileUtils::path(setting('appdir'), 'nytprof');
if (! -d $setting->{profdir}) {
    mkdir $setting->{profdir}
        or die "$setting->{profdir} does not exist and cannot create - $!";
}
if (!-d Dancer::FileUtils::path($setting->{profdir}, 'html')) {
    mkdir Dancer::FileUtils::path($setting->{profdir}, 'html')
        or die "Could not create html dir.";
}


before sub {
    my $path = request->path;
    debug "Original path: $path";
    $path =~ s{^/}{};
    return if $path =~ m{^/nytprof};
    $path =~ s{[^a-z0-9]}{_}gi;
    debug "Modified path: $path";
    DB::enable_profile(
        Dancer::FileUtils::path($setting->{profdir}, "nytprof.out.$path.$$")
    );
};

after sub {
    DB::disable_profile();
    DB::finish_profile();
};

get '/nytprof' => sub {
    my $settings = plugin_setting;
    opendir my $dirh, $setting->{profdir}
        or die "Unable to open profiles dir $setting->{profdir} - $!";
    my @files = grep { /^nytprof.out/ } readdir $dirh;
    closedir $dirh;

    # TODO: A rather prettier list of profile results would be nice.
    return join "<br />\n",
        map { qq{<a href="/nytprof/$_">$_</a>} } @files;
};


# Serve up HTML reports
get '/nytprof/html/**' => sub {
    my ($path) = splat;
    send_file Dancer::FileUtils::path(
        $setting->{profdir}, 'html', @$path
    ), system_path => 1;
};

get '/nytprof/:filename' => sub {
    my $settings = plugin_setting;

    my $profiledata = Dancer::FileUtils::path(
        $settings->{profdir}, param 'filename');

    if (!-f $profiledata) {
        send_error 'not_found';
        return "No such profile run found.";
    }
    
    # See if we already have the HTML for this run stored; if not, invoke
    # nytprofhtml to generate it

    # Right, do we already have generated HTML for this one?  If so, use it
    my $htmldir = Dancer::FileUtils::path(
        $settings->{profdir}, 'html', param('filename')
    );
    if (! -f Dancer::FileUtils::path($htmldir, 'index.html')) {
        # TODO: scrutinise this very carefully to make sure it's not
        # exploitable; check for failure
        system('nytprofhtml', "--file=$profiledata", "--out=$htmldir");
    }

    # Redirect off to view it:
    return redirect '/nytprof/html/' 
        . param('filename') . '/index.html';

};



=head1 AUTHOR

David Precious, C<< <davidp at preshweb.co.uk> >>

=head1 BUGS

Please report any bugs or feature requests at
L<http://github.com/bigpresh/Dancer-Plugin-DevelNYTProf/issues>.

=head1 CONTRIBUTING

This module is developed on GitHub:

L<http://github.com/bigpresh/Dancer-Plugin-DevelNYTProf>

Bug reports, suggestions and pull requests all welcomed!

=head1 SEE ALSO

L<Dancer>

L<Devel::NYTProf>


=head1 LICENSE AND COPYRIGHT

Copyright 2011 David Precious.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.


=cut

1; # End of Dancer::Plugin::NYTProf
