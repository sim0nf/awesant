=head1 NAME

Awesant::Input::Socket - Listen on TCP and/or UDP sockets and ship logs for logstash.

=head1 SYNOPSIS

    Awesant::Input::Socket->new(
        host => "127.0.0.1",
        port => 12345,
        proto => "tcp"
        ssl_ca_file => "/path/to/your.ca",
        ssl_cert_file => "/path/to/your.crt",
        ssl_key_file => "/path/to/your.key",
    );

    # lines = max lines
    # It may be less.
    $input->pull(lines => 100);

=head1 DESCRIPTION

Listen on a TCP or UDP socket and ship events.

=head1 OPTIONS

=head2 host

The ip address to listen on.

Default: 127.0.0.1

=head2 port

The port number to listen on.

Default: no default

=head2 auth

With this option it's possible to set a username and password if you want
that each client have to authorize.

    user:password

See also the documentation of Awesant::Output::Socket.

=head2 proto

The protocol to use. At the moment only tcp is allowed.

Default: tcp

=head2 ssl_ca_file, ssl_cert_file, ssl_key_file

If you want to use ssl connections then you can set the path to your ca, certificate and key file.

This options are equivalent to the options of IO::Socket::SSL.

See cpan http://search.cpan.org/~sullr/IO-Socket-SSL/.

Default: no default

=head2 response

Send a response for each received event.

    response => "ok"

Then the string "ok" is send back to the sender.

See also the documentation of Awesant::Output::Socket.

=head1 METHODS

=head2 new

Create a new input object.

=head2 pull(lines => $number)

This method tries to read the given number of lines of each client connection.

It may be less lines.

=head2 open_socket

Open the listen sockets for TCP and UDP.

=head2 close_socket

Close the socket.

=head2 select

Just an accessor to the selector object.

=head2 socket

Just an accessor to the socket object.

=head2 config

Just an accessor to the config object.

=head2 log

Just an accessor to the logger object.

=head2 validate

Validate the configuration.

=head1 PREREQUISITES

    Log::Handler
    Params::Validate
    IO::Socket::INET
    IO::Select

For SSL only:

    IO::Socket::SSL

=head1 EXPORTS

No exports.

=head1 REPORT BUGS

Please report all bugs to <support(at)bloonix.de>.

=head1 AUTHOR

Jonny Schulz <support(at)bloonix.de>.

=head1 COPYRIGHT

Copyright (C) 2012 by Jonny Schulz. All rights reserved.

=cut

package Awesant::Input::Socket;

use strict;
use warnings;
use IO::Socket::INET;
use IO::Select;
use Params::Validate qw();
use Log::Handler;
use base qw(Class::Accessor::Fast);

__PACKAGE__->mk_accessors(qw/log socket select/);

sub new {
    my $class = shift;
    my $opts  = $class->validate(@_);
    my $self  = bless $opts, $class;

    $self->{log} = Log::Handler->get_logger("awesant");
    $self->open_socket;
    $self->log->info("$class initialized");

    return $self;
}

sub open_socket {
    my $self = shift;
    my $host = $self->{host};
    my $port = $self->{port};
    my $proto = $self->{proto};
    my $sockmod = $self->{sockmod};
    my $sockopts = $self->{sockopts};

    $self->{socket} = $sockmod->new(%$sockopts)
        or die "unable to create socket for $proto:$host:$port - $!";

    $self->{select} = IO::Select->new($self->{socket});
}

sub pull {
    my ($self, %opts) = @_;
    my $response = $self->{response};
    my $count = $opts{lines} || 1;
    my @lines = ();

    my @ready = $self->select->can_read;

    foreach my $fh (@ready) {
        if ($fh == $self->socket) {
            $self->socket->timeout(10);
            my $client = $self->socket->accept;

            if ($! == &Errno::ETIMEDOUT) {
                $self->log->warning("accept runs on a timeout");
            }

            $self->socket->timeout(0);
            next unless $client;
            my $addr = $client->peerhost || "n/a";

            if ($self->{auth}) {
                eval {
                    local $SIG{__DIE__} = sub { alarm(0) };
                    local $SIG{ALRM} = sub { die "timeout" };
                    alarm(5);
                    my $authstr = <$client>;
                    chomp $authstr;
                    if ($authstr ne $self->{auth}) {
                        print $client "0\n";
                        die "noauth";
                    }
                    print $client "1\n";
                    alarm(0);
                };
                if ($@) {
                    my $err = $@;
                    if ($err =~ /^timeout/) {
                        $self->log->warning("timed out connection from $addr as waited for auth string");
                    } else {
                        $self->log->warning("unauthorized connection from $addr");
                    }
                } else {
                    $self->select->add($client);
                }
            } else {
                $self->select->add($client);
            }

            next;
        }

        my $request = <$fh>;

        if (!defined $request) {
            $self->log->debug("remove closed socket of", $fh->peerhost | "n/a");
            $self->select->remove($fh);
            close $fh;
            next;
        }

        if (defined $response) {
            print $fh "$response\n";
        }

        chomp($request);
        push @lines, $request;
        $count--;
        last unless $count;
    }

    return \@lines;
}

sub close_socket {
    my $self = shift;
    $self->DESTROY;
}

sub validate {
    my $class = shift;

    my %options = Params::Validate::validate(@_, {
        host => {
            type => Params::Validate::SCALAR,
            regex => qr/^[\d\.a-f:]+\z/,
        },
        port => {
            type => Params::Validate::SCALAR,
            regex => qr/^\d+\z/,
        },
        auth => {
            type => Params::Validate::SCALAR,
            optional => 1,
        },
        response => {
            type => Params::Validate::SCALAR,
            optional => 1,
        },
        proto => {
            type => Params::Validate::SCALAR,
            regex => qr/^(?:tcp|udp)\z/,
            default => "tcp",
        },
        ssl_ca_file => {
            type => Params::Validate::SCALAR,
            optional => 1,
        },
        ssl_cert_file => {
            type => Params::Validate::SCALAR,
            optional => 1,
        },
        ssl_key_file => {
            type => Params::Validate::SCALAR,
            optional => 1,
        },
    });

    if ($options{ssl_cert_file} && $options{ssl_key_file}) {
        require IO::Socket::SSL;
        $options{sockmod} = "IO::Socket::SSL";
    } elsif ($options{ssl_cert_file} || $options{ssl_key_file}) {
        die "parameter ssl_cert_file and ssl_key_file are both mandatory for ssl sockets";
    }

    if (!$options{sockmod}) {
        $options{sockmod} = "IO::Socket::INET";
    }

    if ($options{sockmod} eq "IO::Socket::SSL" && $options{proto} eq "udp") {
        die "the udp protocol is not available in conjunction with ssl";
    }

    my %sockopts = (
        host  => "LocalAddr",
        port  => "LocalPort",
        proto => "Proto",
        ssl_ca_file   => "SSL_ca_file",
        ssl_cert_file => "SSL_cert_file",
        ssl_key_file  => "SSL_key_file",
    );

    while (my ($opt, $modopt) = each %sockopts) {
        if ($options{$opt}) {
            $options{sockopts}{$modopt} = $options{$opt};
        }
    }

    $options{sockopts}{Listen} = SOMAXCONN;
    $options{sockopts}{Reuse}  = 1;

    return \%options;
}

sub DESTROY {
    my $self = shift;
    my $socket = $self->{socket};

    if ($socket) {
        close $socket;
    }
}

1;
