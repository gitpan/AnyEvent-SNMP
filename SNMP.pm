=head1 NAME

AnyEvent::SNMP - adaptor to integrate Net::SNMP into Anyevent.

=head1 SYNOPSIS

 use AnyEvent::SNMP;
 use Net::SNMP;

 # just use Net::SNMP and AnyEvent as you like:

 # use a condvar to transfer results, this is
 # just an example, you can use a naked callback as well.
 my $cv = AnyEvent->condvar;

 # ... start non-blocking snmp request(s)...
 Net::SNMP->session (-hostname => "127.0.0.1",
                     -community => "public",
                     -nonblocking => 1)
          ->get_request (-callback => sub { $cv->send (@_) });

 # ... do something else until the result is required
 my @result = $cv->wait;

=head1 DESCRIPTION

This module implements an alternative "event dispatcher" for Net::SNMP,
using AnyEvent as a backend.

This integrates Net::SNMP into AnyEvent: You can make non-blocking
Net::SNMP calls and as long as other parts of your program also use
AnyEvent (or some event loop supported by AnyEvent), they will run in
parallel.

Also, the Net::SNMP scheduler is very inefficient with respect to both CPU
and memory usage. Most AnyEvent backends (including the pure-perl backend)
fare much better than the Net::SNMP dispatcher.

A potential disadvantage is that replacing the dispatcher is not at all
a documented thing to do, so future changes in Net::SNP might break this
module (or the many similar ones).

This module does not export anything and does not require you to do
anything special apart from loading it I<before doing any non-blocking
requests with Net::SNMP>. It is recommended but not required to load this
module before C<Net::SNMP>.

=cut

package AnyEvent::SNMP;

no warnings;
use strict qw(subs vars);

# it is possible to do this without loading
# Net::SNMP::Dispatcher, but much more awkward.
use Net::SNMP::Dispatcher;

sub Net::SNMP::Dispatcher::instance {
   AnyEvent::SNMP::
}

use Net::SNMP ();
use AnyEvent ();

our $VERSION = '0.11';

$Net::SNMP::DISPATCHER = instance Net::SNMP::Dispatcher;

our $MESSAGE_PROCESSING = $Net::SNMP::Dispatcher::MESSAGE_PROCESSING;

# avoid the method call
my $timer = sub { shift->timer (@_) };
AnyEvent::post_detect { $timer = AnyEvent->can ("timer") };

our $BUSY;
our %TRANSPORT; # address => [count, watcher]

sub _send_pdu {
   my ($pdu, $retries) = @_;

   # mostly copied from Net::SNMP::Dispatch

   # Pass the PDU to Message Processing so that it can
   # create the new outgoing message.
   my $msg = $MESSAGE_PROCESSING->prepare_outgoing_msg ($pdu);

   if (!defined $msg) {
      --$BUSY;
      # Inform the command generator about the Message Processing error.
      $pdu->status_information ($MESSAGE_PROCESSING->error);
      return; 
   }

   # Actually send the message.
   if (!defined $msg->send) {
      $MESSAGE_PROCESSING->msg_handle_delete ($pdu->msg_id)
         if $pdu->expect_response;

      # A crude attempt to recover from temporary failures.
      if ($retries-- > 0 && ($!{EAGAIN} || $!{EWOULDBLOCK} || $!{ENOSPC})) {
         my $retry_w; $retry_w = AnyEvent->$timer (after => $pdu->timeout, cb => sub {
            undef $retry_w;
            _send_pdu ($pdu, $retries);
         });
      } else {
         --$BUSY;
      }

      # Inform the command generator about the send() error.
      $pdu->status_information ($msg->error);
      return;
   }

   # Schedule the timeout handler if the message expects a response.
   if ($pdu->expect_response) {
      my $transport = $msg->transport;

      # register the transport
      unless ($TRANSPORT{$transport+0}[0]++) {
         $TRANSPORT{$transport+0}[1] = AnyEvent->io (fh => $transport->socket, poll => 'r', cb => sub {
            # Create a new Message object to receive the response
            my ($msg, $error) = Net::SNMP::Message->new (-transport => $transport);

            if (!defined $msg) {
               die sprintf 'Failed to create Message object [%s]', $error;
            }

            # Read the message from the Transport Layer
            if (!defined $msg->recv) {
               # for some reason, connected-oriented transports seem to need this
               unless ($transport->connectionless) {
                  delete $TRANSPORT{$transport+0}
                     unless --$TRANSPORT{$transport+0}[0];
               }

               $msg->error;
               return;
            }

            # For connection-oriented Transport Domains, it is possible to
            # "recv" an empty buffer if reassembly is required.
            if (!$msg->length) {
               return;
            }

            # Hand the message over to Message Processing.
            if (!defined $MESSAGE_PROCESSING->prepare_data_elements ($msg)) {
               $MESSAGE_PROCESSING->error;
               return;
            }

            # Set the error if applicable. 
            $msg->error ($MESSAGE_PROCESSING->error) if $MESSAGE_PROCESSING->error;

            # Cancel the timeout.
            my $rtimeout_w = $msg->timeout_id;
            if ($$rtimeout_w) {
               undef $$rtimeout_w;
               delete $TRANSPORT{$transport+0}
                  unless --$TRANSPORT{$transport+0}[0];

               --$BUSY;
            }

            # Notify the command generator to process the response.
            $msg->process_response_pdu; 
         });
      }

      #####d# timeout_id, wtf?
      $msg->timeout_id (\(my $rtimeout_w =
         AnyEvent->$timer (after => $pdu->timeout, cb => sub {
            my $rtimeout_w = $msg->timeout_id;
            if ($$rtimeout_w) {
               undef $$rtimeout_w;
               delete $TRANSPORT{$transport+0}
                  unless --$TRANSPORT{$transport+0}[0];
            }

            if ($retries--) {
               _send_pdu ($pdu, $retries);
            } else {
               --$BUSY;
               $MESSAGE_PROCESSING->msg_handle_delete ($pdu->msg_id);
               $pdu->status_information ("No response from remote host '%s'", $pdu->hostname);
            }
         })
      )); 
   } else {
     --$BUSY;
   }
}

sub send_pdu($$$) {
   my (undef, $pdu, $delay) = @_;

   ++$BUSY;

   if ($delay > 0) {
      my $delay_w; $delay_w = AnyEvent->$timer (after => $delay, cb => sub {
         undef $delay_w;
         _send_pdu ($pdu, $pdu->retries);
      });
      return 1;
   }

   _send_pdu $pdu, $pdu->retries;
   1
}

sub activate($) {
   AnyEvent->one_event while $BUSY;
}

sub one_event($) {
   die;
}

=head1 SEE ALSO

L<AnyEvent>, L<Net::SNMP>, L<Net::SNMP::EV>.

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

1

