
package DBD::Mock;

sub import {
    shift;
    $DBI::connect_via = "DBD::Mock::Pool::connect" if (@_ && lc($_[0]) eq "pool");
}

# --------------------------------------------------------------------------- #
#   Copyright (c) 2004 Stevan Little, Chris Winters 
#   (spawned from original code Copyright (c) 1994 Tim Bunce)
# --------------------------------------------------------------------------- #
#   You may distribute under the terms of either the GNU General Public
#   License or the Artistic License, as specified in the Perl README file.
# --------------------------------------------------------------------------- #

use strict;
use warnings;

require DBI;

our $VERSION = '0.17';

our $drh    = undef;    # will hold driver handle
our $err    = 0;		# will hold any error codes
our $errstr = '';       # will hold any error messages

sub driver {
    return $drh if defined $drh;
    my ($class, $attributes) = @_;
    $drh = DBI::_new_drh( "${class}::dr", {
        Name        => 'Mock',
        Version     => $DBD::Mock::VERSION,
        Attribution => 'DBD Mock driver by Chris Winters & Stevan Little (orig. from Tim Bunce)',
        Err         => \$DBD::Mock::err,
 		Errstr      => \$DBD::Mock::errstr,
    });
    return $drh;
}

sub CLONE { undef $drh }

sub _error_handler {
    my ($dbh, $error) = @_;
    $dbh->DBI::set_err(1, $error);
    if ($dbh->{'PrintError'}) {
        warn "$error\n";
    }
    elsif ($dbh->{'RaiseError'}) {
        die "$error\n";
    }
}

# NOTE:
# this feature is still quite experimental. It is defaulted to
# be off, but it can be turned on by doing this: 
#    $DBD::Mock::AttributeAliasing++;
# and then turned off by doing:
#    $DBD::Mock::AttributeAliasing = 0;
# we shall see how this feature works out.

our $AttributeAliasing = 0;

my %AttributeAliases = (
    mysql  => {
            db => {
                # aliases can either be a string which is obvious
                mysql_insertid => 'mock_last_insert_id'
            },
            st => {
                # but they can also be a subroutine reference whose
                # first argument will be either the $dbh or the $sth
                # depending upon which context it is aliased in. 
                mysql_insertid => sub { (shift)->{Database}->{'mock_last_insert_id'} }
            }
        },
);

sub _get_mock_attribute_aliases {
    my ($dbname) = @_;
    (exists $AttributeAliases{lc($dbname)})
        || die "Attribute aliases not available for '$dbname'";
    return $AttributeAliases{lc($dbname)};
}

sub _set_mock_attribute_aliases {
    my ($dbname, $dbh_or_sth, $key, $value) = @_;
    return $AttributeAliases{lc($dbname)}->{$dbh_or_sth}->{$key} = $value;
}

########################################
# DRIVER

package DBD::Mock::dr;

use strict;
use warnings;

$DBD::Mock::dr::imp_data_size = 0;

sub connect {
    my ($drh, $dbname, $user, $auth, $attributes) = @_;
    $attributes ||= {};
    if ($dbname && $DBD::Mock::AttributeAliasing) {
        # this is the DB we are mocking
        $attributes->{mock_attribute_aliases} = DBD::Mock::_get_mock_attribute_aliases($dbname);
        $attributes->{mock_database_name} = $dbname;
    }
    my $dbh = DBI::_new_dbh($drh, {
        Name                   => $dbname,       
        # holds statement parsing coderefs/objects
        mock_parser            => [],
        # holds all statements applied to handle until manually cleared
        mock_statement_history => [],
        # ability to fake a failed DB connection
        mock_can_connect       => 1,
        # rest of attributes
        %{ $attributes },
    }) || return undef;
    return $dbh;
}

sub data_sources {
	return ("DBI:Mock:");
}

# Necessary to support DBI < 1.34
# from CPAN RT bug #7057

sub disconnect_all {
    # no-op
}  

sub DESTROY { undef }

########################################
# DATABASE

package DBD::Mock::db;

use strict;
use warnings;

$DBD::Mock::db::imp_data_size = 0;

sub ping {
 	my ( $dbh ) = @_;
 	return $dbh->{mock_can_connect};
}

sub prepare {
    my($dbh, $statement) = @_;

    eval {
        foreach my $parser ( @{ $dbh->{mock_parser} } ) {
            if (ref($parser) eq 'CODE') {
                $parser->($statement);
            }
            else {
                $parser->parse($statement);
            }
        }
    };
    if ($@) {
        my $parser_error = $@;
        chomp $parser_error;
        DBD::Mock::_error_handler($dbh, "Failed to parse statement. Error: ${parser_error}. Statement: ${statement}");
        return undef;
    }
    
    my $sth = DBI::_new_sth($dbh, { Statement => $statement });
    
    $dbh->{mock_last_insert_id}++ if ($statement =~ /^\s*?INSERT/);
    
    $sth->trace_msg("Preparing statement '${statement}'\n", 1);
    
    my %track_params = (statement => $statement);

    # If we have available resultsets seed the tracker with one

    my $rs;
    if ( my $all_rs = $dbh->{mock_rs} ) {
        if ( my $by_name = $all_rs->{named}{$statement} ) {
            $rs = $by_name;
        }
        else {
            $rs = shift @{$all_rs->{ordered}};
        }
    }
    
    if (ref($rs) eq 'ARRAY' && scalar(@{$rs}) > 0 ) {
        my $fields = shift @{$rs};
        $track_params{return_data} = $rs;
        $track_params{fields}      = $fields;
        $sth->STORE(NAME           => $fields);
        $sth->STORE(NUM_OF_FIELDS  => scalar @{$fields});
    }
    else {
        $sth->trace_msg('No return data set in DBH', 1);
    }

 	# do not allow a statement handle to be created if there is no
 	# connection present.

    unless ($dbh->FETCH('Active')) {
        DBD::Mock::_error_handler($dbh, "No connection present");
        return undef;
    }

    # This history object will track everything done to the statement

    my $history = DBD::Mock::StatementTrack->new(%track_params);
    $sth->STORE(mock_my_history => $history);

    # ...now associate the history object with the database handle so
    # people can browse the entire history at once, even for
    # statements opened and closed in a black box

    my $all_history = $dbh->FETCH('mock_statement_history');
    push @{$all_history}, $history;

    return $sth;
}

*prepare_cached = \&prepare;

sub FETCH {
    my ( $dbh, $attrib ) = @_;
    $dbh->trace_msg( "Fetching DB attrib '$attrib'\n" );
    if ($attrib eq 'AutoCommit') {
        return $dbh->{AutoCommit};
    }
 	elsif ($attrib eq 'Active') {
        return $dbh->{mock_can_connect};
    }
    elsif ($attrib eq 'mock_all_history') {
        return $dbh->{mock_statement_history};
    }
    elsif ($attrib eq 'mock_all_history_iterator') {
        return DBD::Mock::StatementTrack::Iterator->new($dbh->{mock_statement_history});
    }    
    elsif ($attrib =~ /^mock/) {
        return $dbh->{$attrib};
    }
    elsif ($attrib =~ /^(private_|dbi_|dbd_|[A-Z])/ ) {
        $dbh->trace_msg("... fetching non-driver attribute ($attrib) that DBI handles\n");    
        return $dbh->SUPER::FETCH($attrib);
    }      
    else {
        if ($dbh->{mock_attribute_aliases}) {
            if (exists ${$dbh->{mock_attribute_aliases}->{db}}{$attrib}) {
                my $mock_attrib = $dbh->{mock_attribute_aliases}->{db}->{$attrib};
                if (ref($mock_attrib) eq 'CODE') {
                   return $mock_attrib->($dbh);
                }
                else {
                    return $dbh->FETCH($mock_attrib);
                }
            }
        }
        $dbh->trace_msg( "... fetching non-driver attribute ($attrib) that DBI doesn't handle\n");
        return $dbh->{$attrib};
    }
}

sub STORE {
    my ( $dbh, $attrib, $value ) = @_;   
    $dbh->trace_msg( "Storing DB attribute '$attrib' with '$value'\n" );
    if ($attrib eq 'AutoCommit') {
        $dbh->{AutoCommit} = $value;
        return $value;
    }
    elsif ( $attrib eq 'mock_clear_history' ) {
        if ( $value ) {
            $dbh->{mock_statement_history} = [];
        }
        return [];
    }
    elsif ( $attrib eq 'mock_add_parser' ) {
        my $parser_type = ref($value);
        my $is_valid_parser;

        if ($parser_type eq 'CODE') {
            $is_valid_parser++;
        }
        elsif ($parser_type && $parser_type !~ /^(ARRAY|HASH|SCALAR)$/) {
            $is_valid_parser = eval { $parser_type->can( 'parse' ) };
        }

        unless ($is_valid_parser) {
            my $error = "Parser must be a code reference or object with 'parse()' " .
                        "method (Given type: '$parser_type')";
            DBD::Mock::_error_handler($dbh, $error);
            return undef;
        }
        push @{$dbh->{mock_parser}}, $value;
        return $value;
    }
    elsif ( $attrib eq 'mock_add_resultset' ) {
        $dbh->{mock_rs} ||= { named   => {},
                              ordered => [] };
        if ( ref $value eq 'ARRAY' ) {
            my @copied_values = @{$value};
            push @{$dbh->{mock_rs}{ordered}}, \@copied_values;
            return \@copied_values;
        }
        elsif ( ref $value eq 'HASH' ) {
            my $name = $value->{sql};
            unless ($name) {
                die "Indexing resultset by name requires passing in 'sql' ",
                    "as hashref key to 'mock_add_resultset'.\n";
            }
            my @copied_values = @{$value->{results}};
            $dbh->{mock_rs}{named}{$name} = \@copied_values;
            return \@copied_values;
        }
        else {
            die "Must provide an arrayref or hashref when adding ",
                "resultset via 'mock_add_resultset'.\n";
        }
    }
    elsif ($attrib eq 'mock_start_insert_id') {
        # we start at one minus the start id
        # so that the increment works
        $dbh->{mock_last_insert_id} = $value - 1;
    }
    elsif ($attrib =~ /^mock/) {  
        return $dbh->{$attrib} = $value;
    }
    elsif ($attrib =~ /^(private_|dbi_|dbd_|[A-Z])/ ) {
        $dbh->trace_msg("... storing non-driver attribute ($attrib) with value ($value) that DBI handles\n");    
        return $dbh->SUPER::STORE($attrib, $value);
    }    
  else {
      $dbh->trace_msg("... storing non-driver attribute ($attrib) with value ($value) that DBI wont handle\n");    
      return $dbh->{$attrib} = $value;
  }
}

sub DESTROY {
    undef
}

########################################
# STATEMENT

package DBD::Mock::st;

use strict;
use warnings;

$DBD::Mock::st::imp_data_size = 0;

sub bind_param {
    my ($sth, $param_num, $val, $attr) = @_;
    my $tracker = $sth->FETCH( 'mock_my_history' );
    $tracker->bound_param( $param_num, $val );
    return 1;
}

sub execute {
    my ($sth, @params) = @_;

    unless ($sth->{Database}->{mock_can_connect}) {
        DBD::Mock::_error_handler($sth->{Database}, "No connection present");
        return 0;
    }

    my $tracker = $sth->FETCH( 'mock_my_history' );
    if ( @params ) {
        $tracker->bound_param_trailing( @params );
    }
    $tracker->mark_executed;
    my $fields = $tracker->fields;
    $sth->STORE( NUM_OF_PARAMS => $tracker->num_params );
    return '0E0';
}

sub fetch {
    my ($sth) = @_;

    unless ($sth->{Database}->{mock_can_connect}) {
        DBD::Mock::_error_handler($sth->{Database}, "No connection present");
        return undef;
    }

    my $tracker = $sth->FETCH( 'mock_my_history' );
    return $tracker->next_record;
}

sub finish {
    my ($sth) = @_;
    $sth->FETCH( 'mock_my_history' )->is_finished( 'yes' );
}

sub rows {
    my ($sth) = @_;
    $sth->FETCH('mock_num_rows');
}

sub FETCH {
    my ( $sth, $attrib ) = @_;
    $sth->trace_msg( "Fetching ST attribute '$attrib'\n" );
    my $tracker = $sth->{mock_my_history};
    $sth->trace_msg( "Retrieved tracker: " . ref( $tracker ) . "\n" );
    if ( $attrib eq 'NAME' ) {
        return $tracker->fields;
    }
    elsif ( $attrib eq 'NUM_OF_FIELDS' ) {
        return $tracker->num_fields;
    }
    elsif ( $attrib eq 'NUM_OF_PARAMS' ) {
        return $tracker->num_params;
    }
    elsif ( $attrib eq 'TYPE' ) {
        my $num_fields = $tracker->num_fields;
        return [ map { $DBI::SQL_VARCHAR } ( 0 .. $num_fields ) ];
    }
    elsif ( $attrib eq 'Active' ) {
        return $tracker->is_active;
    }
    elsif ( $attrib !~ /^mock/ ) {
        if ($sth->{Database}->{mock_attribute_aliases}) {
            if (exists ${$sth->{Database}->{mock_attribute_aliases}->{st}}{$attrib}) {
                my $mock_attrib = $sth->{Database}->{mock_attribute_aliases}->{st}->{$attrib};
                if (ref($mock_attrib) eq 'CODE') {
                   return $mock_attrib->($sth);
                }
                else {
                    return $sth->FETCH($mock_attrib);
                }
            }
        }     
        return $sth->SUPER::FETCH( $attrib );
    }

    # now do our stuff...

    if ( $attrib eq 'mock_my_history' ) {
        return $tracker;
    }
    if ( $attrib eq 'mock_statement' ) {
        return $tracker->statement;
    }
    elsif ( $attrib eq 'mock_params' ) {
        return $tracker->bound_params;
    }
    elsif ( $attrib eq 'mock_num_records' || $attrib eq 'mock_num_rows' ) {
        return $tracker->num_rows;
    }    
    elsif ( $attrib eq 'mock_current_record_num' ) {
        return $tracker->current_record_num;
    }
    elsif ( $attrib eq 'mock_fields' ) {
        return $tracker->fields;
    }
    elsif ( $attrib eq 'mock_is_executed' ) {
        return $tracker->is_executed;
    }
    elsif ( $attrib eq 'mock_is_finished' ) {
        return $tracker->is_finished;
    }
    elsif ( $attrib eq 'mock_is_depleted' ) {
        return $tracker->is_depleted;
    }
    else {   
        die "I don't know how to retrieve statement attribute '$attrib'\n";
    }
}

sub STORE {
    my ($sth, $attrib, $value) = @_;
    $sth->trace_msg( "Storing ST attribute '$attrib'\n" );
    if ($attrib =~ /^mock/) {
        return $sth->{$attrib} = $value;
    }
    elsif ($attrib eq 'NAME') {
        # no-op...
        return;
    }
    else {   
        $value ||= 0;
        return $sth->SUPER::STORE( $attrib, $value );
    }
}

sub DESTROY { undef }

##########################
# Database Pooling 
# (Apache::DBI emulation)

package DBD::Mock::Pool;

use strict;
use warnings;

my $connection;

sub connect {
	my $class = "DBD::Mock::Pool";
	$class = shift unless ref($_[0]);
	my ($driver_handle, $username, $password, $attributes) = @_;
    $connection = bless $driver_handle->connect(), "DBD::Mock::Pool::db" unless $connection;
	return $connection;
}

package DBD::Mock::Pool::db;

use strict;
use warnings;

our @ISA = qw(DBI::db);

sub disconnect { 1 }

########################################
# TRACKER

package DBD::Mock::StatementTrack;

use strict;
use warnings;

sub new {
    my ($class, %params) = @_;
    # these params have default values
    # but can be overridden
    $params{return_data}  ||= [];
    $params{fields}       ||= [];
    $params{bound_params} ||= [];
    $params{statement}    ||= "";    
    # these params should never be overridden
    # and should always start out in a default
    # state to assure the sanity of this class    
    $params{is_executed}        = 'no';
    $params{is_finished}        = 'no';
    $params{current_record_num} = 0;
    # NOTE:
    # changed from \%params here because that 
    # would bind the hash sent in so that it 
    # would reflect alterations in the object
    # this violates encapsulation
    my $self = bless { %params }, $class;
    return $self;
}

sub num_fields {
    my ($self) = @_;
    return scalar @{$self->{fields}};
}

sub num_rows {
    my ($self) = @_;
    return scalar @{$self->{return_data}};
}

sub num_params {
    my ($self) = @_;
    return scalar @{$self->{bound_params}};
}

sub bound_param {
    my ($self, $param_num, $value) = @_;
    $self->{bound_params}->[$param_num - 1] = $value;
    return $self->bound_params;
}

sub bound_param_trailing {
    my ($self, @values) = @_;
    push @{$self->{bound_params}}, @values;
}

# Rely on the DBI's notion of Active: a statement is active if it's
# currently in a SELECT and has more records to fetch

sub is_active {
    my ($self) = @_;
    return 0 unless $self->statement =~ /^\s*select/ism;
    return 0 unless $self->is_executed eq 'yes';
    return 0 if     $self->is_depleted;
    return 1;
}

sub is_finished {
    my ($self, $value) = @_;
    if (defined $value && $value eq 'yes' ) {
        $self->{is_finished} = 'yes';
        $self->current_record_num(0);
        $self->{return_data} = [];
    }
    elsif (defined $value) {
        $self->{is_finished} = 'no';
    }
    return $self->{is_finished};
}

####################
# RETURN VALUES

sub mark_executed {
    my ($self) = @_;
    $self->is_executed('yes');
    $self->current_record_num(0);
}

sub next_record {
    my ($self) = @_;
    return undef if $self->is_depleted;
    my $rec_num = $self->current_record_num;
    my $rec = $self->return_data->[$rec_num];
    $self->current_record_num($rec_num + 1);
    return $rec;
}

sub is_depleted {
    my ($self) = @_;
    return ($self->current_record_num >= scalar @{$self->return_data});
}

# DEBUGGING AID

sub to_string {
    my ($self) = @_;
    return join "\n" => (
                  $self->{statement},
                  "Values: [" . join( '] [', @{ $self->{bound_params} } ) . "]",
                  "Records: on $self->{current_record_num} of " . scalar(@{$self->return_data}) . "\n",
                  "Executed? $self->{is_executed}; Finished? $self->{is_finished}" 
                  );
}

# PROPERTIES 

# boolean

sub is_executed {
    my ($self, $yes_no) = @_;
    $self->{is_executed} = $yes_no if defined $yes_no;
    return ($self->{is_executed} eq 'yes') ? 'yes' : 'no';
}

# single-element fields

sub statement {
    my ($self, $value) = @_;
    $self->{statement} = $value if defined $value;
    return $self->{statement};
}

sub current_record_num {
    my ($self, $value) = @_;
    $self->{current_record_num} = $value if defined $value;
    return $self->{current_record_num};
}

# multi-element fields

sub return_data {
    my ($self, @values) = @_;
    push @{$self->{return_data}}, @values if scalar @values;
    return $self->{return_data};
}

sub fields {
    my ($self, @values) = @_;
    push @{$self->{fields}}, @values if scalar @values;
    return $self->{fields};
}

sub bound_params {
    my ($self, @values) = @_;
    push @{$self->{bound_params}}, @values if scalar @values;
    return $self->{bound_params};
}

package DBD::Mock::StatementTrack::Iterator;

use strict;
use warnings;

sub new {
    my ($class, $history) = @_;
    return bless { 
            pointer => 0, 
            history => $history || [] 
            } => $class;
}

sub next {
    my ($self) = @_;  
    return unless $self->{pointer} < scalar(@{$self->{history}});
    return $self->{history}->[$self->{pointer}++];
}

1;

__END__

=head1 NAME

DBD::Mock - Mock database driver for testing

=head1 SYNOPSIS

 use DBI;

 # ...connect as normal, using 'Mock' as your driver name
 my $dbh = DBI->connect( 'DBI:Mock:', '', '' )
               || die "Cannot create handle: $DBI::errstr\n";
 
 # ...create a statement handle as normal and execute with parameters
 my $sth = $dbh->prepare( 'SELECT this, that FROM foo WHERE id = ?' );
 $sth->execute( 15 );
 
 # Now query the statement handle as to what has been done with it
 my $params = $sth->{mock_params};
 print "Used statement: ", $sth->{mock_statement}, "\n",
       "Bound parameters: ", join( ', ', @{ $params } ), "\n";

=head1 DESCRIPTION

=head2 Purpose

Testing with databases can be tricky. If you are developing a system
married to a single database then you can make some assumptions about
your environment and ask the user to provide relevant connection
information. But if you need to test a framework that uses DBI,
particularly a framework that uses different types of persistence
schemes, then it may be more useful to simply verify what the
framework is trying to do -- ensure the right SQL is generated and
that the correct parameters are bound. C<DBD::Mock> makes it easy to
just modify your configuration (presumably held outside your code) and
just use it instead of C<DBD::Foo> (like L<DBD::Pg> or L<DBD::mysql>)
in your framework.

There is no distinct area where using this module makes sense. (Some
people may successfully argue that this is a solution looking for a
problem...) Indeed, if you can assume your users have something like
L<DBD::AnyData> or L<DBD::SQLite> or if you do not mind creating a
dependency on them then it makes far more sense to use these
legitimate driver implementations and test your application in the
real world -- at least as much of the real world as you can create in
your tests...

And if your database handle exists as a package variable or something
else easily replaced at test-time then it may make more sense to use
L<Test::MockObject> to create a fully dynamic handle. There is an
excellent article by chromatic about using L<Test::MockObject> in this
and other ways, strongly recommended. (See L<SEE ALSO> for a link)

=head2 How does it work?

C<DBD::Mock> comprises a set of classes used by DBI to implement a
database driver. But instead of connecting to a datasource and
manipulating data found there it tracks all the calls made to the
database handle and any created statement handles. You can then
inspect them to ensure what you wanted to happen actually
happened. For instance, say you have a configuration file with your
database connection information:

 [DBI]
 dsn      = DBI:Pg:dbname=myapp
 user     = foo
 password = bar

And this file is read in at process startup and the handle stored for
other procedures to use:

 package ObjectDirectory;
 
 my ( $DBH );
 
 sub run_at_startup {
     my ( $class, $config ) = @_;
     $config ||= read_configuration( ... );
     my $dsn  = $config->{DBI}{dsn};
     my $user = $config->{DBI}{user};
     my $pass = $config->{DBI}{password};
     $DBH = DBI->connect( $dsn, $user, $pass ) || die ...;
 }
 
 sub get_database_handle {
     return $DBH;
 }

A procedure might use it like this (ignoring any error handling for
the moment):

 package My::UserActions;
 
 sub fetch_user {
     my ( $class, $login ) = @_;
     my $dbh = ObjectDirectory->get_database_handle;
     my $sql = q{
         SELECT login_name, first_name, last_name, creation_date, num_logins
           FROM users
          WHERE login_name = ?
     };
     my $sth = $dbh->prepare( $sql );
     $sth->execute( $login );
     my $row = $sth->fetchrow_arrayref;
     return ( $row ) ? User->new( $row ) : undef;
 }

So for the purposes of our tests we just want to ensure that:

=over 4

=item 1.

The right SQL is being executed

=item 2.

The right parameters are bound

=back

Assume whether the SQL actually B<works> or not is irrelevant for this
test :-)

To do that our test might look like:

 my $config = ObjectDirectory->read_configuration( ... );
 $config->{DBI}{dsn} = 'DBI:Mock:';
 ObjectDirectory->run_at_startup( $config );
 my $login_name = 'foobar';
 my $user = My::UserActions->fetch_user( $login_name );
 
 # Get the handle from ObjectDirectory; this is the same handle used
 # in the 'fetch_user()' procedure above
 my $dbh = ObjectDirectory->get_database_handle();
 
 # Ask the database handle for the history of all statements executed
 # against it
 my $history = $dbh->{mock_all_history};
 
 # Now query that history record to see if our expectations match
 # reality
 is( scalar @{ $history }, 1,
     'Correct number of statements executed' );
 my $login_st = $history->[0];
 like( $login_st->statement, qr/SELECT login_name.*FROM users WHERE login_name = ?/sm,
       'Correct statement generated' );
 my $params = $login_st->bound_params;
 is( scalar @{ $params }, 1,
     'Correct number of parameters bound' );
 is( $params->[0], $login_name,
     'Correct value for parameter 1' );

 # Reset the handle for future operations
 $dbh->{mock_clear_history} = 1;

The list of properties and what they return is listed below. But in an overall view:

=over 4

=item *

A database handle contains the history of all statements created
against it. Other properties set for the handle (e.g., 'PrintError',
'RaiseError') are left alone and can be queried as normal, but they do
not affect anything. (A future feature may track the sequence/history
of these assignments but if there is no demand it probably will not
get implemented.)

=item *

A statement handle contains the statement it was prepared with plus
all bound parameters or parameters passed via C<execute()>. It can
also contain predefined results for the statement handle to 'fetch',
track how many fetches were called and what its current record is.

=back

=head2 A Word of Warning

This may be an incredibly naive implementation of a DBD. But it works
for me...

=head1 PROPERTIES

Since this is a normal DBI statement handle we need to expose our
tracking information as properties (accessed like a hash) rather than
methods.

=head2 Database Handle Properties

B<mock_all_history>

Returns an array reference with all history
(a.k.a. C<DBD::Mock::StatementTrack>) objects created against the
database handle in the order they were created. Each history object
can then report information about the SQL statement used to create it,
the bound parameters, etc..

B<mock_all_history_iterator>

Returns a C<DBD::Mock::StatementTrack::Iterator> object which will iterate
through the current set of C<DBD::Mock::StatementTrack> object in the 
history. See the B<DBD::Mock::StatementTrack::Iterator> documentation below
for more information.

B<mock_clear_history>

If set to a true value all previous statement history operations will
be erased. This B<includes> the history of currently open handles, so
if you do something like:

 my $dbh = get_handle( ... );
 my $sth = $dbh->prepare( ... );
 $dbh->{mock_clear_history} = 1;
 $sth->execute( 'Foo' );

You will have no way to learn from the database handle that the
statement parameter 'Foo' was bound.

This is useful mainly to ensure you can isolate the statement
histories from each other. A typical sequence will look like:

 set handle to framework
 perform operations
 analyze mock database handle
 reset mock database handle history
 perform more operations
 analyze mock database handle
 reset mock database handle history
 ...

B<mock_can_connect>

This statement allows you to simulate a downed database connection.
This is useful in testing how your application/tests will perform in
the face of some kind of catastrophic event such as a network outage
or database server failure. It is a simple boolean value which
defaults to on, and can be set like this:

 # turn the database off
 $dbh->{mock_can_connect} = 0;
 
 # turn it back on again
 $dbh->{mock_can_connect} = 1;

The statement handle checks this value as well, so something like this
will fail in the expected way:

 $dbh = DBI->connect( 'DBI:Mock:', '', '' );
 $dbh->{mock_can_connect} = 0;
 
 # blows up!
 my $sth = eval { $dbh->prepare( 'SELECT foo FROM bar' ) });
 if ( $@ ) {
     # Here, $DBI::errstr = 'No connection present'
 }

Turning off the database after a statement prepare will fail on the
statement C<execute()>, which is hopefully what you would expect:

 $dbh = DBI->connect( 'DBI:Mock:', '', '' );
 
 # ok!
 my $sth = eval { $dbh->prepare( 'SELECT foo FROM bar' ) });
 $dbh->{mock_can_connect} = 0;
 
 # blows up!
 $sth->execute;

Similarly:

 $dbh = DBI->connect( 'DBI:Mock:', '', '' );
 
 # ok!
 my $sth = eval { $dbh->prepare( 'SELECT foo FROM bar' ) });
 
 # ok!
 $sth->execute;

 $dbh->{mock_can_connect} = 0;
 
 # blows up!
 my $row = $sth->fetchrow_arrayref;

Note: The handle attribute C<Active> and the handle method C<ping>
will behave according to the value of C<mock_can_connect>. So if
C<mock_can_connect> were to be set to 0 (or off), then both C<Active>
and C<ping> would return false values (or 0).

B<mock_add_resultset( \@resultset | \%sql_and_resultset )>

This stocks the database handle with a record set, allowing you to
seed data for your application to see if it works properly.. Each
recordset is a simple arrayref of arrays with the first arrayref being
the fieldnames used. Every time a statement handle is created it asks
the database handle if it has any resultsets available and if so uses
it.

Here is a sample usage, partially from the test suite:

 my @user_results = (
    [ 'login', 'first_name', 'last_name' ],
    [ 'cwinters', 'Chris', 'Winters' ],
    [ 'bflay', 'Bobby', 'Flay' ],
    [ 'alincoln', 'Abe', 'Lincoln' ],
 );
 my @generic_results = (
    [ 'foo', 'bar' ],
    [ 'this_one', 'that_one' ],
    [ 'this_two', 'that_two' ],
 );
 
 my $dbh = DBI->connect( 'DBI:Mock:', '', '' );
 $dbh->{mock_add_resultset} = \@user_results;    # add first resultset
 $dbh->{mock_add_resultset} = \@generic_results; # add second resultset
 my ( $sth );
 eval {
     $sth = $dbh->prepare( 'SELECT login, first_name, last_name FROM foo' );
     $sth->execute();
 };

 # this will fetch rows from the first resultset...
 my $row1 = $sth->fetchrow_arrayref;
 my $user1 = User->new( login => $row->[0],
                        first => $row->[1],
                        last  => $row->[2] );
 is( $user1->full_name, 'Chris Winters' );
 
 my $row2 = $sth->fetchrow_arrayref;
 my $user2 = User->new( login => $row->[0],
                        first => $row->[1],
                        last  => $row->[2] );
 is( $user2->full_name, 'Bobby Flay' );
 ...
 
 my $sth_generic = $dbh->prepare( 'SELECT foo, bar FROM baz' );
 $sth_generic->execute;
 
 # this will fetch rows from the second resultset...
 my $row = $sth->fetchrow_arrayref;

You can also associate a resultset with a particular SQL statement
instead of adding them in the order they will be fetched:

 $dbh->{mock_add_resultset} = {
     sql     => 'SELECT foo, bar FROM baz',
     results => [
         [ 'foo', 'bar' ],
         [ 'this_one', 'that_one' ],
         [ 'this_two', 'that_two' ],
     ],
 };

This will return the given results when the statement 'SELECT foo, bar
FROM baz' is prepared. Note that they will be returned B<every time>
the statement is prepared, not just the first. (This behavior could
change.)

It should also be noted that the C<rows> method will return the number of
records stocked in the result set. So if your code/application makes use of
the C<$sth-E<gt>rows> method for things like UPDATE and DELETE calls you
should stock the result set like so:

 $dbh->{mock_add_resultset} = {
     sql     => 'UPDATE foo SET baz = 1, bar = 2',
     # this will appear to have updated 3 rows
     results => [[ 'rows' ], [], [], []],
 };

 # or ...
 
 $dbh->{mock_add_resultset} = {
     sql     => 'DELETE FROM foo WHERE bar = 2',
     # this will appear to have deleted 1 row
     results => [[ 'rows' ], []],
 };
 
Now I admit this is not the most elegant way to go about this, but it works
for me for now, and until I can come up with a better method, or someone sends
me a patch ;) it will do for now.

B<mock_last_insert_id>

This attribute is incremented each time an INSERT statement is passed
to prepare on a per-handle basis. It's starting value can be set with 
the 'mock_start_insert_id' attribute (see below).

B<mock_start_insert_id>

This attribute can be used to set a start value for the 'mock_last_insert_id'
attribute. It can also be used to effectively reset the 'mock_last_insert_id'
attribute as well.

B<mock_add_parser>

DBI provides some simple parsing capabilities for 'SELECT' statements
to ensure that placeholders are bound properly. And typically you may
simply want to check after the fact that a statement is syntactically
correct, or at least what you expect.

But other times you may want to parse the statement as it is prepared
rather than after the fact. There is a hook in this mock database
driver for you to provide your own parsing routine or object.

The syntax is simple:

 $dbh->{mock_add_parser} = sub {
     my ( $sql ) = @_;
     unless ( $sql =~ /some regex/ ) {
         die "does not contain secret fieldname";
     }
 };

You can also add more than one for a handle. They will be called in
order, and the first one to fail will halt the parsing process:

 $dbh->{mock_add_parser} = \&parse_update_sql;
 $dbh->{mock_add-parser} = \&parse_insert_sql;

Depending on the 'PrintError' and 'RaiseError' settings in the
database handle any parsing errors encountered will issue a C<warn> or
C<die>. No matter what the statement handle will be C<undef>.

Instead of providing a subroutine reference you can use an object. The
only requirement is that it implements the method C<parse()> and takes
a SQL statement as the only argument. So you should be able to do
something like the following (untested):

 my $parser = SQL::Parser->new( 'mysql', { RaiseError => 1 } );
 $dbh->{mock_add_parser} = $parser;

=head2 Statement Handle Properties

B<Active>

Returns true if the handle is a 'SELECT' and has more records to
fetch, false otherwise. (From the DBI.)

B<mock_statement>

The SQL statement this statement handle was C<prepare>d with. So if
the handle were created with:

 my $sth = $dbh->prepare( 'SELECT * FROM foo' );

This would return:

 SELECT * FROM foo

The original statement is unmodified so if you are checking against it
in tests you may want to use a regex rather than a straight equality
check. (However if you use a phrasebook to store your SQL externally
you are a step ahead...)

B<mock_fields>

Fields used by the statement. As said elsewhere we do no analysis or
parsing to find these, you need to define them beforehand. That said,
you do not actually need this very often.

Note that this returns the same thing as the normal statement property
'FIELD'.

B<mock_params>

Returns an arrayref of parameters bound to this statement in the order
specified by the bind type. For instance, if you created and stocked a
handle with:

 my $sth = $dbh->prepare( 'SELECT * FROM foo WHERE id = ? AND is_active = ?' );
 $sth->bind_param( 2, 'yes' );
 $sth->bind_param( 1, 7783 );

This would return:

 [ 7738, 'yes' ]

The same result will occur if you pass the parameters via C<execute()>
instead:

 my $sth = $dbh->prepare( 'SELECT * FROM foo WHERE id = ? AND is_active = ?' );
 $sth->execute( 7783, 'yes' );

B<mock_records>

An arrayref of arrayrefs representing the records the mock statement
was stocked with.

B<mock_num_records>

Number of records the mock statement was stocked with; if never
stocked it is still 0. (Some weirdos might expect undef...)

B<mock_num_rows>

This returns the same value as I<mock_num_records>. And is what is returned
by the C<rows> method of the statement handle.

B<mock_current_record_num>

Current record the statement is on; returns 0 in the instances when
you have not yet called C<execute()> and if you have not yet called a
C<fetch> method after the execute.

B<mock_is_executed>

Whether C<execute()> has been called against the statement
handle. Returns 'yes' if so, 'no' if not.

B<mock_is_finished>

Whether C<finish()> has been called against the statement
handle. Returns 'yes' if so, 'no' if not.

B<mock_is_depleted>

Returns 'yes' if all the records in the recordset have been
returned. If no C<fetch()> was executed against the statement, or If
no return data was set this will return 'no'.

B<mock_my_history>

Returns a C<DBD::Mock::StatementTrack> object which tracks the
actions performed by this statement handle. Most of the actions are
separately available from the properties listed above, so you should
never need this.

=head1 DBD::Mock::Pool

This module can be used to emulate Apache::DBI style DBI connection 
pooling. Just as with Apache::DBI, you must enable DBD::Mock::Pool 
before loading DBI.

 use DBD::Mock qw(Pool);
 # followed by ...
 use DBI;

While this may not seem to make a lot of sense in a single-process testing 
scenario, it can be useful when testing code which assumes a multi-process
Apache::DBI pooled environment.

=head1 DBD::Mock::StatementTrack

Under the hood this module does most of the work with a
C<DBD::Mock::StatementTrack> object. This is most useful when you are
reviewing multiple statements at a time, otherwise you might want to
use the C<mock_*> statement handle attributes instead.

=head2 Methods

B<new( %params )>

Takes the following parameters:

=over 4

=item *

B<return_data>: Arrayref of return data records

=item *

B<fields>: Arrayref of field names

=item *

B<bound_params>: Arrayref of bound parameters

=back

B<statement> (Statement attribute 'mock_statement')

Gets/sets the SQL statement used.

B<fields>  (Statement attribute 'mock_fields')

Gets/sets the fields to use for this statement.

B<bound_params>  (Statement attribute 'mock_params')

Gets/set the bound parameters to use for this statement.

B<return_data>  (Statement attribute 'mock_records')

Gets/sets the data to return when asked (that is, when someone calls
'fetch' on the statement handle).

B<current_record_num> (Statement attribute 'mock_current_record_num')

Gets/sets the current record number.

B<is_active()> (Statement attribute 'Active')

Returns true if the statement is a SELECT and has more records to
fetch, false otherwise. (This is from the DBI, see the 'Active' docs
under 'ATTRIBUTES COMMON TO ALL HANDLES'.)

B<is_executed( $yes_or_no )> (Statement attribute 'mock_is_executed')

Sets the state of the tracker 'executed' flag.

B<is_finished( $yes_or_no )> (Statement attribute 'mock_is_finished')

If set to 'yes' tells the tracker that the statement is finished. This
resets the current record number to '0' and clears out the array ref
of returned records.

B<is_depleted()> (Statement attribute 'mock_is_depleted')

Returns true if the current record number is greater than the number
of records set to return.

B<num_fields>

Returns the number of fields set in the 'fields' parameter.

B<num_rows>

Returns the number of records in the current result set.

B<num_params>

Returns the number of parameters set in the 'bound_params' parameter.

B<bound_param( $param_num, $value )>

Sets bound parameter C<$param_num> to C<$value>. Returns the arrayref
of currently-set bound parameters. This corresponds to the
'bind_param' statement handle call.

B<bound_param_trailing( @params )>

Pushes C<@params> onto the list of already-set bound parameters.

B<mark_executed()>

Tells the tracker that the statement has been executed and resets the
current record number to '0'.

B<next_record()>

If the statement has been depleted (all records returned) returns
undef; otherwise it gets the current recordfor returning, increments
the current record number and returns the current record.

B<to_string()>

Tries to give an decent depiction of the object state for use in
debugging.

=head1 DBD::Mock::StatementTrack::Iterator

This object can be used to iterate through the current set of C<DBD::Mock::StatementTrack> objects in the history by fetching the 'mock_all_history_iterator' attribute from a database handle. This object is very simple and is meant to be a convience to make writing long test script easier. Aside from the constructor (C<new>) this object has only one method.

B<next>

Calling C<next> will return the next C<DBD::Mock::StatementTrack> object in the history. If there are no more C<DBD::Mock::StatementTrack> objects available, then this method will return undef. 

=head1 EXPERIMENTAL FUNCTIONALITY

All functionality listed here is highly experimental and should be used with great caution (if at all). 

=over 

=item Attribute Aliasing

Basically this feature allows you to alias attributes to other attributes. So for instance, you can alias a commonly expected attribute like 'mysql_insertid' to something DBD::Mock already has like 'mock_last_insert_id'. While you can also just set 'mysql_insertid' yourself, this functionality allows it to take advantage of things like the autoincrementing of the 'mock_last_insert_id' attribute. 

Right now this feature is highly experimental, and has been added as a first attempt to automatically handle some of the DBD specific attributes which are commonly used/accessed in DBI programming. The functionality is off by default so as to not cause any issues with backwards compatability, but can easily be turned on and off like this:

  # turn it on
  $DBD::Mock::AttributeAliasing++;
  
  # turn it off
  $DBD::Mock::AttributeAliasing = 0;

Once this is turned on, you will need to choose a database specific attribute aliasing table like so:

  DBI->connect('dbi:Mock:MySQL', '', '');

The 'MySQL' in the DSN will be picked up and the MySQL specific attribute aliasing will be used.

Right now only MySQL is supported by this feature, and even that support is very minimal. Currently the MySQL C<$dbh> and C<$sth> attributes 'mysql_insertid' are aliased to the C<$dbh> attribute 'mock_last_insert_id'. It is possible to add more aliases though, using the C<DBD::Mock:_set_mock_attribute_aliases> function (see the source code for details).

=back

=head1 BUGS

=over

=item Odd $dbh attribute behavior

When writing the test suite I encountered some odd behavior with some C<$dbh> attributes. I still need to get deeper into how DBD's work to understand what it is that is actually doing wrong.

=back

=head1 TO DO

=over

=item Make DBD specific handlers

Each DBD has its own quirks and issues, it would be nice to be able to handle those issues with DBD::Mock in some way. I have an number of ideas already, but little time to sit down and really flesh them out. If you have any suggestions or thoughts, feel free to email me with them.

=item Enhance the DBD::Mock::StatementTrack object

I would like to have the DBD::Mock::StatementTrack object handle more of the mock_* attributes. This would encapsulate much of the mock_* behavior in one place, which would be a good thing. 

I would also like to add the ability to bind a subroutine (or possibly an object) to the result set, so that the results can be somewhat more dynamic and allow for a more realistic interaction. 

=back

=head1 CODE COVERAGE

I use L<Devel::Cover> to test the code coverage of my tests, below is the L<Devel::Cover> report on this module test suite.

 ------------------------ ------ ------ ------ ------ ------ ------ ------
 File                       stmt branch   cond    sub    pod   time  total
 ------------------------ ------ ------ ------ ------ ------ ------ ------
 DBD/Mock.pm                89.1   82.0   86.5   93.3    0.0  100.0   87.2
 ------------------------ ------ ------ ------ ------ ------ ------ ------
 Total                      89.1   82.0   86.5   93.3    0.0  100.0   87.2
 ------------------------ ------ ------ ------ ------ ------ ------ ------

=head1 SEE ALSO

L<DBI>

L<DBD::NullP>, which provided a good starting point

L<Test::MockObject>, which provided the approach

Test::MockObject article - L<http://www.perl.com/pub/a/2002/07/10/tmo.html>

=head1 COPYRIGHT

Copyright (c) 2004 Stevan Little, Chris Winters. All rights reserved.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHORS

Chris Winters E<lt>chris@cwinters.comE<gt>

Stevan Little E<lt>stevan@iinteractive.comE<gt>
