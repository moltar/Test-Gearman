package Test::Gearman;

use Moose;
use Test::TCP qw();
use File::Which qw();
use Carp qw();
use Proc::Guard qw();

use Gearman::XS qw(:constants);
use Gearman::XS::Worker;
use Gearman::XS::Client;

use version; our $VERSION = version->declare('v0.1.0');

# ABSTRACT: A class for testing and mocking Gearman workers.

=head1 SYNOPSIS

 use Test::Gearman;

 my $tg = Test::Gearman->new(
     functions => {
         reverse => sub {
             my $job      = shift;
             my $workload = $job->workload();
             my $result   = reverse($workload);

             return $result;
         },
     },
 );

 ## now you can either get a client object from Test::Gearman object
 my $res = $tg->client->do('reverse', 'this is a test');

 ## or build your own
 use Gearman::XS::Client;
 my $client = Gearman::XS::Client->new;
 $client->add_server($tg->host, $tg->port);
 my $res = $client->do('reverse', 'some other test string');

=head1 DESCRIPTION

Test::Gearman is a class for testing Gearman workers.

This class only works with C version of gearmand, and L<Gearman::XS>
bindings.

=head1 PUBLIC ATTRIBUTES

=head2 functions

A HashRef of CodeRefs that stores work function names as keys and
a CodeRef as work to be done.

=head3 function_names()

Returns a list of all function names.

=head3 get_function($function_name)

Returns a CodeRef for the given function name.

=cut

has functions => (
    is       => 'ro',
    isa      => 'HashRef[CodeRef]',
    traits   => ['Hash'],
    required => 1,
    handles  => {
        function_names => 'keys',
        get_function   => 'get',
    },
);

=head2 gearmand_bin

Path to Gearman daemon binary. If one is not provided it tries
to find it in the C<$PATH>.

B<Note>: this must be a C version of gearmand, and not the Perl version
as they have different interfaces.

You can also set the path to the binary via C<$ENV{GEARMAND}>.

=cut

has gearmand_bin => (
    is      => 'ro',
    isa     => 'Str',
    lazy    => 1,
    builder => '_build_gearmand_bin',
);

sub _build_gearmand_bin {
    ## find gearmand binary in $PATH
    return $ENV{GEARMAND} || File::Which::which('gearmand') || q{};
}

=head2 host

Host to which Gearman daemon will bind.

Default is 127.0.0.1.

=cut

has host => (
    is      => 'ro',
    isa     => 'Str',
    default => '127.0.0.1',
);

=head2 port

Port on which gearmand runs. It is picked randomly at the start, but
you can manually specify a port if you wish.

=cut

has port => (
    is      => 'ro',
    isa     => 'Int',
    lazy    => 1,
    builder => '_build_port',
);

sub _build_port {
    return Test::TCP::empty_port();
}

=head2 worker_timeout

Worker timeout in seconds.

Default is 5.

=cut

has worker_timeout => (
    is      => 'ro',
    isa     => 'Int',
    default => 5,
);

=head2 client_timeout

Client timeout in seconds.

Default is 5.

=cut

has client_timeout => (
    is      => 'ro',
    isa     => 'Int',
    default => 5,
);

=head2 client

An instance of L<Gearman::XS::Client> that you can use to inject jobs.

=cut

has client => (
    is      => 'ro',
    isa     => 'Gearman::XS::Client',
    lazy    => 1,
    builder => '_build_client',
);

sub _build_client {
    my $self = shift;

    my $client = Gearman::XS::Client->new;

    my $ret = $client->add_server($self->host, $self->port);
    if ($ret != GEARMAN_SUCCESS) {
        Carp::croak($client->error());
    }

    $client->set_timeout(1000 * $self->client_timeout);

    return $client;
}

=head1 PRIVATE ATTRIBUTES

=head2 server

An instance of L<Proc::Guard> that runs gearmand server.

=cut

has server => (
    is        => 'ro',
    isa       => 'Proc::Guard',
    lazy      => 1,
    builder   => '_build_server',
    predicate => 'has_server',
);

sub _build_server {
    my $self = shift;

    ## get port on which we'll run
    my $port = $self->port;

    ## build gearmand args
    my %args = (
        'listen'   => $self->host,
        'port'     => $port,
        'log-file' => 'stderr',
    );
    my @args = map { sprintf('--%s=%s', $_, $args{$_}) } keys %args;

    ## launch gearmand
    my $proc = Proc::Guard->new(command => [ $self->gearmand_bin, @args ]);

    ## wait for port to initialize
    Test::TCP::wait_port($port);

    ## only now we can return with confidence
    return $proc;
}

=head2 worker

An instance of L<Proc::Guard> class that runs workers.

=cut

has worker => (
    is        => 'ro',
    isa       => 'Proc::Guard',
    lazy      => 1,
    builder   => '_build_worker',
    predicate => 'has_worker',

);

sub _build_worker {
    my $self = shift;

    my $server = $self->server;
    my $worker = Gearman::XS::Worker->new;

    ## add our server instance
    my $ret = $worker->add_server($self->host, $self->port);
    if ($ret != GEARMAN_SUCCESS) {
        Carp::croak($worker->error());
    }

    ## assign functions
    foreach my $function_name ($self->function_names) {
        my $ret = $worker->add_function($function_name, 1000 * $self->worker_timeout, $self->get_function($function_name), {});
        if ($ret != GEARMAN_SUCCESS) {
            Carp::croak($worker->error());
        }
    }

    ## now fork and loop
    return Proc::Guard->new(code => sub {
        while (1) {
            if (GEARMAN_SUCCESS != $worker->work()) {
                Carp::croak($worker->error());
            }
        }
    });
}

sub BUILD {
    my $self = shift;

    my $bin = $self->gearmand_bin;

    ## make sure the path exists first of all
    unless ($bin && -e $bin) {
        Carp::croak("The gearmand ($bin) does not exist.");
    }

    ## make sure it is executable
    unless (-x $bin) {
        Carp::croak("The gearmand ($bin) is not an executable.");
    }

    ## make sure we have a C binary, and not a Perl version one
    open (my $fh, '<', $bin) or Carp::croak("Cannot open $bin: $!");
    my $shebang = <$fh>;
    close $fh;

    if (substr($shebang, 0, 2) eq '#!') {
        Carp::croak("The gearmand ($bin) appears to be a Perl version. This only support C version.");
    }

    ## launch server
    $self->server;

    ## launch workers
    $self->worker;
}

sub DEMOLISH {
    my $self = shift;

    ## clean up and stop server and workers
    ## otherwise in the event of error they will
    ## hang and never exit properly
    ##
    ## we also need to check whether the attribute
    ## was initialized, as in the case when the BUILD fails
    ## early
    $self->worker->stop if $self->has_worker;
    $self->server->stop if $self->has_server;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1; ## eof
