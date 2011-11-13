#!perl

use Test::More tests => 1;

BEGIN {
    use_ok( 'Dancer::Plugin::NYTProf' ) || print "Bail out!
";
}

diag( "Testing Dancer::Plugin::NYTProf $Dancer::Plugin::NYTProf::VERSION, Perl $], $^X" );
