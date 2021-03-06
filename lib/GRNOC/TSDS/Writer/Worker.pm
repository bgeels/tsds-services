package GRNOC::TSDS::Writer::Worker;

use Moo;

use GRNOC::TSDS::DataType;
use GRNOC::TSDS::Constants;
use GRNOC::TSDS::DataDocument;
use GRNOC::TSDS::EventDocument;
use GRNOC::TSDS::Writer::DataMessage;
use GRNOC::TSDS::Writer::EventMessage;

use MongoDB;
use Net::AMQP::RabbitMQ;
use Redis;
use Redis::DistLock;
use Cache::Memcached::Fast;
use Tie::IxHash;
use JSON::XS;
use Math::Round qw( nlowmult );
use Time::HiRes qw( time );
use Try::Tiny;

use Data::Dumper;

### constants ###

use constant LOCK_TIMEOUT => 10;
use constant LOCK_RETRIES => 10;
use constant DATA_CACHE_EXPIRATION => 60 * 60;
use constant MEASUREMENT_CACHE_EXPIRATION => 60 * 60;
use constant QUEUE_PREFETCH_COUNT => 20;
use constant QUEUE_FETCH_TIMEOUT => 10 * 1000;
use constant RECONNECT_TIMEOUT => 10;

### required attributes ###

has config => ( is => 'ro',
                required => 1 );

has logger => ( is => 'ro',
                required => 1 );

### internal attributes ###

has is_running => ( is => 'rwp',
                    default => 0 );

has data_types => ( is => 'rwp',
                    default => sub { {} } );

has mongo_rw => ( is => 'rwp' );

has rabbit => ( is => 'rwp' );

has redis => ( is => 'rwp' );

has memcache => ( is => 'rwp' );

has locker => ( is => 'rwp' );

has json => ( is => 'rwp' );

### public methods ###

sub start {

    my ( $self ) = @_;

    $self->logger->debug( "Starting." );

    # flag that we're running
    $self->_set_is_running( 1 );

    # change our process name
    $0 = "tsds_writer [worker]";

    # setup signal handlers
    $SIG{'TERM'} = sub {

        $self->logger->info( "Received SIG TERM." );
        $self->stop();
    };

    $SIG{'HUP'} = sub {

        $self->logger->info( "Received SIG HUP." );
    };

    # create JSON object
    my $json = JSON::XS->new();

    $self->_set_json( $json );

    # connect to mongo
    my $mongo_host = $self->config->get( '/config/mongo/@host' );
    my $mongo_port = $self->config->get( '/config/mongo/@port' );
    my $rw_user    = $self->config->get( "/config/mongo/readwrite" );

    $self->logger->debug( "Connecting to MongoDB as readwrite on $mongo_host:$mongo_port." );

    my $mongo;
    eval {
        $mongo = MongoDB::MongoClient->new(
            host => "$mongo_host:$mongo_port",
            username => $rw_user->{'user'},
            password => $rw_user->{'password'}
            );
    };
    if($@){
        die "Could not connect to Mongo: $@";
    }

    $self->_set_mongo_rw( $mongo );

    # connect to redis
    my $redis_host = $self->config->get( '/config/redis/@host' );
    my $redis_port = $self->config->get( '/config/redis/@port' );

    $self->logger->debug( "Connecting to Redis $redis_host:$redis_port." );

    my $redis = Redis->new( server => "$redis_host:$redis_port" );

    $self->_set_redis( $redis );

    # create locker
    $self->logger->debug( 'Creating locker.' );

    my $locker = Redis::DistLock->new( servers => [$redis],
                                       retry_count => LOCK_RETRIES );

    $self->_set_locker( $locker );

    # connect to memcache
    my $memcache_host = $self->config->get( '/config/memcache/@host' );
    my $memcache_port = $self->config->get( '/config/memcache/@port' );

    $self->logger->debug( "Connecting to memcached $memcache_host:$memcache_port." );

    my $memcache = Cache::Memcached::Fast->new( {'servers' => [{'address' => "$memcache_host:$memcache_port", 'weight' => 1}]} );

    $self->_set_memcache( $memcache );

    # connect to rabbit
    $self->_rabbit_connect();

    $self->logger->debug( 'Starting RabbitMQ consume loop.' );

    # continually consume messages from rabbit queue, making sure we have to acknowledge them
    return $self->_consume_loop();
}

sub stop {

    my ( $self ) = @_;

    $self->logger->debug( 'Stopping.' );

    $self->_set_is_running( 0 );
}

### private methods ###

sub _consume_loop {

    my ( $self ) = @_;

    while ( 1 ) {

        # have we been told to stop?
        if ( !$self->is_running ) {

            $self->logger->debug( 'Exiting consume loop.' );
            return 0;
        }

        # receive the next rabbit message
        my $rabbit_message;

        try {

            $rabbit_message = $self->rabbit->recv( QUEUE_FETCH_TIMEOUT );
        }

        catch {

            $self->logger->error( "Error receiving rabbit message: $_" );

            # reconnect to rabbit since we had a failure
            $self->_rabbit_connect();
        };

        # didn't get a message?
        if ( !$rabbit_message ) {

            $self->logger->debug( 'No message received.' );

            # re-enter loop to retrieve the next message
            next;
        }

        # try to JSON decode the messages
        my $messages;

        try {

            $messages = $self->json->decode( $rabbit_message->{'body'} );
        }

        catch {

            $self->logger->error( "Unable to JSON decode message: $_" );
        };

        if ( !$messages ) {

            try {

                # reject the message and do NOT requeue it since its malformed JSON
                $self->rabbit->reject( 1, $rabbit_message->{'delivery_tag'}, 0 );
            }

            catch {

                $self->logger->error( "Unable to reject rabbit message: $_" );

                # reconnect to rabbit since we had a failure
                $self->_rabbit_connect();
            };
        }

        # retrieve the next message from rabbit if we couldn't decode this one
        next if ( !$messages );

        # make sure its an array (ref) of messages
        if ( ref( $messages ) ne 'ARRAY' ) {

            $self->logger->error( "Message body must be an array." );

            try {

                # reject the message and do NOT requeue since its not properly formed
                $self->rabbit->reject( 1, $rabbit_message->{'delivery_tag'}, 0 );
            }

            catch {

                $self->logger->error( "Unable to reject rabbit message: $_" );

                # reconnect to rabbit since we had a failure
                $self->_rabbit_connect();
            };

            next;
        }

        my $num_messages = @$messages;
        $self->logger->debug( "Processing message containing $num_messages updates." );

        my $t1 = time();

        my $success = $self->_consume_messages( $messages );

        my $t2 = time();
        my $delta = $t2 - $t1;

        $self->logger->debug( "Processed $num_messages updates in $delta seconds." );

        # didn't successfully consume the messages, so reject but requeue the entire message to try again
        if ( !$success ) {

            $self->logger->debug( "Rejecting rabbit message, requeueing." );

            try {

                $self->rabbit->reject( 1, $rabbit_message->{'delivery_tag'}, 1 );
            }

            catch {

                $self->logger->error( "Unable to reject rabbit message: $_" );

                # reconnect to rabbit since we had a failure
                $self->_rabbit_connect();
            };
        }

        # successfully consumed message, acknowledge it to rabbit
        else {

            $self->logger->debug( "Acknowledging successful message." );

            try {

                $self->rabbit->ack( 1, $rabbit_message->{'delivery_tag'} );
            }

            catch {

                $self->logger->error( "Unable to acknowledge rabbit message: $_" );

                # reconnect to rabbit since we had a failure
                $self->_rabbit_connect();
            };
        }
    }
}

sub _consume_messages {

    my ( $self, $messages ) = @_;

    # gather all messages to process
    my $data_to_process = [];
    my $events_to_process = [];

    # handle every TSDS message that came within the rabbit message
    foreach my $message ( @$messages ) {

        # make sure message is an object/hash (ref)
        if ( ref( $message ) ne 'HASH' ) {

            $self->logger->error( "Messages must be an object/hash of data, skipping." );
            next;
        }

        my $type = $message->{'type'};
        my $time = $message->{'time'};
        my $interval = $message->{'interval'};
        my $values = $message->{'values'};
        my $meta = $message->{'meta'};
        my $affected = $message->{'affected'};
        my $text = $message->{'text'};
        my $start = $message->{'start'};
        my $end = $message->{'end'};
        my $event_type = $message->{'event_type'};
        my $identifier = $message->{'identifier'};

        # make sure a type was specified
        if ( !defined( $type ) ) {

            $self->logger->error( "No type specified, skipping message." );
            next;
        }

        # does it appear to be an event message?
        if ( $type =~ /^(.+)\.event$/ ) {

            my $data_type_name = $1;
            my $data_type = $self->data_types->{$data_type_name};

            # we haven't seen this data type before, re-fetch them
            if ( !$data_type ) {

                my $success = 1;

                # this involves communicating to mongodb which may fail
                try {

                    $self->_fetch_data_types();
                }

                # requeue the message to try again later if mongo communication fails
                catch {

                    $self->logger->error( "Unable to fetch data types from MongoDB." );

                    $success = 0;
                };

                # dont bother handling any more of the messages in this rabbit message
                return 0 if !$success;

                $data_type = $self->data_types->{$data_type_name};
            }

            # detect unknown data type, ignore it
            if ( !$data_type ) {

                $self->logger->warn( "Unknown data type '$data_type_name', skipping." );
                next;
            }

            my $event_message;

            try {

                $event_message = GRNOC::TSDS::Writer::EventMessage->new( data_type => $data_type,
                                                                         affected => $affected,
                                                                         text => $text,
                                                                         start => $start,
                                                                         end => $end,
                                                                         identifier => $identifier,
                                                                         type => $event_type );
            }

            catch {

                $self->logger->error( $_ );
            };

            # include this to our list of events to process if it was valid
            push( @$events_to_process, $event_message ) if $event_message;
        }

        # must be a data message
        else {

            my $data_type = $self->data_types->{$type};

            # we haven't seen this data type before, re-fetch them
            if ( !$data_type ) {

                my $success = 1;

                # this involves communicating to mongodb, which may fail
                try {

                    $self->_fetch_data_types();
                }

                # requeue the message to try again later if mongo communication fails
                catch {

                    $self->logger->error( "Unable to fetch data types from MongoDB." );

                    $success = 0;
                };

                # dont bother handling any more of the messages in this rabbit message
                return 0 if !$success;

                $data_type = $self->data_types->{$type};
            }

            # detected unknown data type, ignore it
            if ( !$data_type ) {

                $self->logger->warn( "Unknown data type '$type', skipping." );
                next;
            }

            my $data_message;

            try {

                $data_message = GRNOC::TSDS::Writer::DataMessage->new( data_type => $data_type,
                                                                       time => $time,
                                                                       interval => $interval,
                                                                       values => $values,
                                                                       meta => $meta );
            }

            catch {

                $self->logger->error( $_ );
            };

            # include this to our list of data to process if it was valid
            push( @$data_to_process, $data_message ) if $data_message;
        }
    }

    # process all of the data points and events within this message
    my $success = 1;

    try {

        $self->_process_data_messages( $data_to_process ) if ( @$data_to_process > 0 );
        $self->_process_event_messages( $events_to_process ) if ( @$events_to_process > 0 );
    }

    catch {

        $self->logger->error( "Error processing messages: $_" );

        $success = 0;
    };

    return $success;
}

sub _process_event_messages {

    my ( $self, $messages ) = @_;

    # all unique documents we're handling (and their corresponding events)
    my $unique_documents = {};

    # handle every message
    foreach my $message ( @$messages ) {

        my $data_type = $message->data_type;
        my $start = $message->start;
        my $end = $message->end;
        my $affected = $message->affected;
        my $text = $message->text;
        my $type = $message->type;
        my $event = $message->event;

        # determine proper start and end time of document
        my $doc_start = nlowmult( EVENT_DOCUMENT_DURATION, $start );
        my $doc_end = $doc_start + EVENT_DOCUMENT_DURATION;

        # determine the document that this event would belong within
        my $document = GRNOC::TSDS::EventDocument->new( data_type => $data_type,
                                                        start => $doc_start,
                                                        end => $doc_end,
                                                        type => $type );

        # mark the document for this event if one hasn't been set already
        my $unique_doc = $unique_documents->{$data_type->name}{$type}{$document->start}{$document->end};

        # we've never handled an event for this document before
        if ( !$unique_doc ) {

            # mark it as being a new unique document we need to handle
            $unique_documents->{$data_type->name}{$type}{$document->start}{$document->end} = $document;
            $unique_doc = $unique_documents->{$data_type->name}{$type}{$document->start}{$document->end};
        }

        # add this as another event to update/set in the document
        $unique_doc->add_event( $event );
    }

    # handle every distinct document that we'll need to update
    my @data_types = keys( %$unique_documents );

    foreach my $data_type ( @data_types ) {

        my @types = keys( %{$unique_documents->{$data_type}} );

        foreach my $type ( @types ) {

            my @starts = keys( %{$unique_documents->{$data_type}{$type}} );

            foreach my $start ( @starts ) {

                my @ends = keys( %{$unique_documents->{$data_type}{$type}{$start}} );

                foreach my $end ( @ends ) {

                    my $document = $unique_documents->{$data_type}{$type}{$start}{$end};

                    # process this event document, including all events contained within it
                    $self->_process_event_document( $document );

                    # all done with this document, remove it so we don't hold onto its memory
                    delete( $unique_documents->{$data_type}{$type}{$start}{$end} );
                }
            }
        }
    }
}

sub _process_data_messages {

    my ( $self, $messages ) = @_;

    # all unique value types we're handling per each data type
    my $unique_data_types = {};
    my $unique_value_types = {};

    # all unique measurements we're handling
    my $unique_measurements = {};

    # all unique documents we're handling (and their corresponding data points)
    my $unique_documents = {};

    # handle every message sent, ordered by their timestamp in ascending order
    foreach my $message ( sort { $a->time <=> $b->time } @$messages ) {

        my $data_type = $message->data_type;
        my $measurement_identifier = $message->measurement_identifier;
        my $interval = $message->interval;
        my $data_points = $message->data_points;
        my $time = $message->time;
        my $meta = $message->meta;

        # mark this data type as being found
        $unique_data_types->{$data_type->name} = $data_type;

        # have we handled this measurement already?
        my $unique_measurement = $unique_measurements->{$data_type->name}{$measurement_identifier};

        if ( $unique_measurement ) {

            # keep the older start time, just update its meta data with the latest
            $unique_measurements->{$data_type->name}{$measurement_identifier}{'meta'} = $meta;
        }

        # never seen this measurement before
        else {

            # mark this measurement as being found, and include its meta data and start time
            $unique_measurements->{$data_type->name}{$measurement_identifier} = {'meta' => $meta,
                                                                                 'start' => $time,
                                                                                 'interval' => $interval};
        }

        # determine proper start and end time of document
        my $doc_length = $interval * HIGH_RESOLUTION_DOCUMENT_SIZE;
        my $start = nlowmult( $doc_length, $time );
        my $end = $start + $doc_length;

        # determine the document that this message would belong within
        my $document = GRNOC::TSDS::DataDocument->new( data_type => $data_type,
                                                       measurement_identifier => $measurement_identifier,
                                                       interval => $interval,
                                                       start => $start,
                                                       end => $end );

        # mark the document for this data point if one hasn't been set already
        my $unique_doc = $unique_documents->{$data_type->name}{$measurement_identifier}{$document->start}{$document->end};

        # we've never handled a data point for this document before
        if ( !$unique_doc ) {

            # mark it as being a new unique document we need to handle
            $unique_documents->{$data_type->name}{$measurement_identifier}{$document->start}{$document->end} = $document;
            $unique_doc = $unique_documents->{$data_type->name}{$measurement_identifier}{$document->start}{$document->end};
        }

        # handle every data point that was included in this message
        foreach my $data_point ( @$data_points ) {

            my $value_type = $data_point->value_type;

            # add this as another data point to update/set in the document
            $unique_doc->add_data_point( $data_point );

            # mark this value type as being found
            $unique_value_types->{$data_type->name}{$value_type} = 1;
        }
    }

    # get cache ids for all unique measurements we'll ask about
    my @measurement_cache_ids;

    my @data_types = keys( %$unique_measurements );

    foreach my $data_type ( @data_types ) {

        my @measurement_identifiers = keys( %{$unique_measurements->{$data_type}} );

        foreach my $measurement_identifier ( @measurement_identifiers ) {

            my $cache_id = $self->_get_cache_id( type => $data_type,
                                                 collection => 'measurements',
                                                 identifier => $measurement_identifier );

            push( @measurement_cache_ids, $cache_id );
        }
    }

    if ( @measurement_cache_ids ) {

        # grab measurements from our cache
        my $measurement_cache_results = $self->memcache->get_multi( @measurement_cache_ids );

        # potentially create new measurement entries that we've never seen before
        @data_types = keys( %$unique_measurements );

        foreach my $data_type ( @data_types ) {

            my @measurement_identifiers = keys( %{$unique_measurements->{$data_type}} );

            foreach my $measurement_identifier ( @measurement_identifiers ) {

                my $cache_id = shift( @measurement_cache_ids );

                # this measurement exists in our cache, dont bother creating it
                next if ( $measurement_cache_results->{$cache_id} );

                # potentially create a new entry unless someone else beats us to it
                my $meta = $unique_measurements->{$data_type}{$measurement_identifier}{'meta'};
                my $start = $unique_measurements->{$data_type}{$measurement_identifier}{'start'};
                my $interval = $unique_measurements->{$data_type}{$measurement_identifier}{'interval'};

                $self->_create_measurement_document( identifier => $measurement_identifier,
                                                     data_type => $unique_data_types->{$data_type},
                                                     meta => $meta,
                                                     start => $start,
                                                     interval => $interval );
            }
        }
    }

    # potentially update the metadata value types for every distinct one found
    @data_types = keys( %$unique_value_types );

    foreach my $data_type ( @data_types ) {

        my @value_types = keys( %{$unique_value_types->{$data_type}} );

        $self->_update_metadata_value_types( data_type => $unique_data_types->{$data_type},
                                             value_types => \@value_types );
    }

    # handle every distinct document that we'll need to update
    @data_types = keys( %$unique_documents );

    foreach my $data_type ( @data_types ) {

        my @measurement_identifiers = keys( %{$unique_documents->{$data_type}} );

        foreach my $measurement_identifier ( @measurement_identifiers ) {

            my @starts = keys( %{$unique_documents->{$data_type}{$measurement_identifier}} );

            foreach my $start ( @starts ) {

                my @ends = keys( %{$unique_documents->{$data_type}{$measurement_identifier}{$start}} );

                foreach my $end ( @ends ) {

                    my $document = $unique_documents->{$data_type}{$measurement_identifier}{$start}{$end};

                    # process this data document, including all data points contained within it
                    $self->_process_data_document( $document );

                    # all done with this document, remove it so we don't hold onto its memory
                    delete( $unique_documents->{$data_type}{$measurement_identifier}{$start}{$end} );
                }
            }
        }
    }
}

sub _process_event_document {

    my ( $self, $document ) = @_;

    my $data_type = $document->data_type->name;
    my $type = $document->type;
    my $start = $document->start;
    my $end = $document->end;

    $self->logger->debug( "Processing event document $data_type / $type / $start / $end." );

    # get lock for this event document
    my $lock_id = $self->_get_lock_id( type => $data_type,
                                       collection => 'event',
                                       identifier => $type,
                                       start => $start,
                                       end => $end );

    my $lock = $self->locker->lock( $lock_id, LOCK_TIMEOUT );

    my $cache_id = $self->_get_cache_id( type => $data_type,
                                         collection => 'event',
                                         identifier => $type,
                                         start => $start,
                                         end => $end );

    # its already in our cache, seen it before
    if ( my $cached = $self->memcache->get( $cache_id ) ) {

        $self->logger->debug( 'Found document in cache, updating.' );

        # retrieve the full old document from mongo
        my $old_doc = GRNOC::TSDS::EventDocument->new( data_type => $document->data_type,
                                                       type => $type,
                                                       start => $start,
                                                       end => $end )->fetch();

        # update it and its events accordingly
        $self->_update_event_document( new_document => $document,
                                       old_document => $old_doc );


        # update the cache with its new info
        $self->memcache->set( $cache_id,
                              1,
                              DATA_CACHE_EXPIRATION );
    }

    # not in cache, we'll have to query mongo to see if its there
    else {

        $self->logger->debug( 'Document not found in cache.' );

        # retrieve the full old document from mongo
        my $old_doc = GRNOC::TSDS::EventDocument->new( data_type => $document->data_type,
                                                       type => $type,
                                                       start => $start,
                                                       end => $end )->fetch();

        # document exists in mongo, so we'll need to update it
        if ( $old_doc ) {

            $self->logger->debug( 'Document exists in mongo, updating.' );

            # update it and its events accordingly
            $self->_update_event_document( new_document => $document,
                                           old_document => $old_doc );
        }

        # doesn't exist in mongo, we'll need to create it along with its data points we added to it
        else {

            $self->logger->debug( 'Document does not exist in mongo, creating.' );

            $document->create();
        }

        # update our cache with the doc info
        $self->memcache->set( $cache_id,
                              1,
                              DATA_CACHE_EXPIRATION );
    }

    $self->logger->debug( "Finished processing event document $data_type / $type / $start / $end." );

    # release lock on this document now that we're done
    $self->locker->release( $lock );
}

sub _process_data_document {

    my ( $self, $document ) = @_;

    my $data_type = $document->data_type->name;
    my $measurement_identifier = $document->measurement_identifier;
    my $start = $document->start;
    my $end = $document->end;

    $self->logger->debug( "Processing data document $data_type / $measurement_identifier / $start / $end." );

    # get lock for this data document
    my $lock_id = $self->_get_lock_id( type => $data_type,
                                       collection => 'data',
                                       identifier => $measurement_identifier,
                                       start => $start,
                                       end => $end );

    my $lock = $self->locker->lock( $lock_id, LOCK_TIMEOUT );

    my $cache_id = $self->_get_cache_id( type => $data_type,
                                         collection => 'data',
                                         identifier => $measurement_identifier,
                                         start => $start,
                                         end => $end );

    # its already in our cache, seen it before
    if ( my $cached = $self->memcache->get( $cache_id ) ) {

        $self->logger->debug( 'Found document in cache, updating.' );

        my $old_value_types = $cached->{'value_types'};

        # update existing document along with its new data points
        $document = $self->_update_data_document( document => $document,
                                                  old_value_types => $old_value_types );

        # update the cache with its new info
        $self->memcache->set( $cache_id,
                              {'value_types' => $document->value_types},
                              DATA_CACHE_EXPIRATION );
    }

    # not in cache, we'll have to query mongo to see if its there
    else {

        $self->logger->debug( 'Document not found in cache.' );

        # retrieve the full updated doc from mongo
        my $live_doc = $document->fetch();

        # document exists in mongo, so we'll need to update it
        if ( $live_doc ) {

            $self->logger->debug( 'Document exists in mongo, updating.' );

            # update existing document along with its new data points
            $document = $self->_update_data_document( document => $document,
                                                      old_value_types => $live_doc->value_types );
        }

        # doesn't exist in mongo, we'll need to create it along with the data points provided, and
        # make sure there are no overlaps with other docs due to interval change, etc.
        else {

            $self->logger->debug( 'Document does not exist in mongo, creating.' );

            $document = $self->_create_data_document( $document );
        }

        # update our cache with the doc info
        $self->memcache->set( $cache_id,
                              {'value_types' => $document->value_types},
                              DATA_CACHE_EXPIRATION );
    }

    $self->logger->debug( "Finished processing document $data_type / $measurement_identifier / $start / $end." );

    # release lock on this document now that we're done
    $self->locker->release( $lock );
}

sub _update_event_document {

    my ( $self, %args ) = @_;

    my $old_document = $args{'old_document'};
    my $new_document = $args{'new_document'};

    my $old_events = $old_document->events;
    my $new_events = $new_document->events;

    # index the old events by their unique criteria
    my $event_index = {};

    foreach my $old_event ( @$old_events ) {

        my $start = $old_event->start;
        my $identifier = $old_event->identifier;

        $event_index->{$start}{$identifier} = $old_event;
    }

    foreach my $new_event ( @$new_events ) {

        my $start = $new_event->start;
        my $identifier = $new_event->identifier;

        # either replace/update existing event or add brand new event
        $event_index->{$start}{$identifier} = $new_event;
    }

    my $events = [];

    my @starts = keys( %$event_index );

    foreach my $start ( @starts ) {

        my @identifiers = keys( %{$event_index->{$start}} );

        foreach my $identifier ( @identifiers ) {

            my $event = $event_index->{$start}{$identifier};

            push( @$events, $event );
        }
    }

    $new_document->events( $events );
    $new_document->update();
}

sub _create_data_document {

    my ( $self, $document ) = @_;

    # before we insert this new document, we will want to check for existing documents which
    # may have overlapping data with this new one.  this can happen if there was an interval
    # change, since that affects the start .. end range of the document

    my $data_type = $document->data_type;
    my $identifier = $document->measurement_identifier;
    my $start = $document->start;
    my $end = $document->end;
    my $interval = $document->interval;

    $self->logger->debug( "Creating new data document $identifier / $start / $end." );

    # help from http://eli.thegreenplace.net/2008/08/15/intersection-of-1d-segments
    my $query = Tie::IxHash->new( 'identifier' => $identifier,
                                  'start' => {'$lt' => $end},
                                  'end' => {'$gt' => $start} );

    # get this document's data collection
    my $data_collection = $data_type->database->get_collection( 'data' );

    $self->logger->debug( 'Finding existing overlapping data documents before creation.' );

    # the ids of the overlaps we found
    my @overlap_ids;

    # the cache ids of the overlaps we found
    my @overlap_cache_ids;

    # the locks we had to acquire
    my @locks;

    # unique documents that the data points, after altering their interval, will belong in
    my $unique_documents = {};

    # add this new document as one of the unique documents that will need to get created
    $unique_documents->{$identifier}{$start}{$end} = $document;

    # specify index hint to address occasional performance problems executing this query
    my $overlaps = $data_collection->find( $query )->hint( 'identifier_1_start_1_end_1' )->fields( {'interval' => 1,
                                                                                                    'start' => 1,
                                                                                                    'end' => 1} );

    # handle every existing overlapping doc, if any
    while ( my $overlap = $overlaps->next ) {

        my $id = $overlap->{'_id'};
        my $overlap_interval = $overlap->{'interval'};
        my $overlap_start = $overlap->{'start'};
        my $overlap_end = $overlap->{'end'};

        # keep this as one of the docs that will need removed later
        push( @overlap_ids, $id );

        # determine cache id for this doc
        my $cache_id = $self->_get_cache_id( type => $data_type->name,
                                             collection => 'data',
                                             identifier => $identifier,
                                             start => $overlap_start,
                                             end => $overlap_end );

        push( @overlap_cache_ids, $cache_id );

        # grab lock for this doc
        my $lock_id = $self->_get_lock_id( type => $data_type->name,
                                           collection => 'data',
                                           identifier => $identifier,
                                           start => $overlap_start,
                                           end => $overlap_end );

        my $lock = $self->locker->lock( $lock_id, LOCK_TIMEOUT );

        push( @locks, $lock );

        $self->logger->debug( "Found overlapping data document with interval: $overlap_interval start: $overlap_start end: $overlap_end." );

        # create object representation of this duplicate doc
        my $overlap_doc = GRNOC::TSDS::DataDocument->new( data_type => $data_type,
                                                          measurement_identifier => $identifier,
                                                          interval => $overlap_interval,
                                                          start => $overlap_start,
                                                          end => $overlap_end );

        # fetch entire doc to grab its data points
        $overlap_doc->fetch( data => 1 );

        # handle every data point in this overlapping doc
        my $data_points = $overlap_doc->data_points;

        foreach my $data_point ( @$data_points ) {

            # set the *new* interval we'll be using for this data point
            $data_point->interval( $interval );

            # determine proper start and end time of *new* document
            my $doc_length = $interval * HIGH_RESOLUTION_DOCUMENT_SIZE;
            my $new_start = nlowmult( $doc_length, $data_point->time );
            my $new_end = $new_start + $doc_length;

            # determine the *new* document that this message would belong within
            my $new_document = GRNOC::TSDS::DataDocument->new( data_type => $data_type,
                                                               measurement_identifier => $identifier,
                                                               interval => $interval,
                                                               start => $new_start,
                                                               end => $new_end );

            # mark the document for this data point if one hasn't been set already
            my $unique_doc = $unique_documents->{$identifier}{$new_start}{$new_end};

            # we've never handled a data point for this document before
            if ( !$unique_doc ) {

                # mark it as being a new unique document we need to handle
                $unique_documents->{$identifier}{$new_start}{$new_end} = $new_document;
                $unique_doc = $unique_documents->{$identifier}{$new_start}{$new_end};
            }

            # add this as another data point to update/set in the document, if needed
            $unique_doc->add_data_point( $data_point ) if ( defined $data_point->value );
        }
    }

    # process all new documents that get created as a result of splitting the old document up
    my @measurement_identifiers = keys( %$unique_documents );

    foreach my $measurement_identifier ( @measurement_identifiers ) {

        my @starts = keys( %{$unique_documents->{$measurement_identifier}} );

        foreach my $start ( @starts ) {

            my @ends = keys( %{$unique_documents->{$measurement_identifier}{$start}} );

            foreach my $end ( @ends ) {

                my $unique_document = $unique_documents->{$measurement_identifier}{$start}{$end};

                $self->logger->debug( "Creating new data document $measurement_identifier / $start / $end." );
                $unique_document->create();

                # must also create a cache entry for it since it now exists
                my $cache_id = $self->_get_cache_id( type => $data_type->name,
                                                     collection => 'data',
                                                     identifier => $measurement_identifier,
                                                     start => $start,
                                                     end => $end );

                $self->memcache->set( $cache_id,
                                      {'value_types' => $document->value_types},
                                      DATA_CACHE_EXPIRATION );
            }
        }
    }

    # remove all old documents that are getting replaced with new docs
    if ( @overlap_ids > 0 ) {

        # first remove from mongo
        $data_collection->remove( {'_id' => {'$in' => \@overlap_ids}} );

        # also must remove them from our cache since they no longer exist!
        $self->memcache->delete_multi( @overlap_cache_ids );

        # release all locks on all extra docs we created since we're done
        foreach my $lock ( @locks ) {

            $self->locker->release( $lock );
        }
    }

    return $document;
}

sub _update_data_document {

    my ( $self, %args ) = @_;

    my $document = $args{'document'};
    my $old_value_types = $args{'old_value_types'};

    # do we need to add any value types to the document?
    my @value_types_to_add;

    foreach my $new_value_type ( keys %{$document->value_types} ) {

        # already in the doc
        next if ( $old_value_types->{$new_value_type} );

        # must be new
        push( @value_types_to_add, $new_value_type );
    }

    # did we find at least one new value type not in the doc?
    if ( @value_types_to_add ) {

        $self->logger->debug( "Adding new value types " . join( ',', @value_types_to_add ) . " to document." );

        $document->add_value_types( \@value_types_to_add );
    }

    $document->update();

    return $document;
}

sub _get_lock_id {

    my ( $self, %args ) = @_;

    my $cache_id = $self->_get_cache_id( %args );
    my $lock_id = "lock__$cache_id";

    $self->logger->debug( "Getting lock id $lock_id." );

    return $lock_id;
}

sub _get_cache_id {

    my ( $self, %args ) = @_;

    my $type = $args{'type'};
    my $collection = $args{'collection'};
    my $identifier = $args{'identifier'};
    my $start = $args{'start'};
    my $end = $args{'end'};

    my $id = $type . '__' . $collection;

    # include identifier in id if its given
    if ( defined( $identifier ) ) {

        $id .= '__' . $identifier;
    }

    if ( defined( $start ) || defined( $end ) ) {

        $id .= '__' . $start;
        $id .= '__' . $end;
    }

    $self->logger->debug( "Getting cache id $id." );

    return $id;
}

sub _update_metadata_value_types {

    my ( $self, %args ) = @_;

    my $data_type = $args{'data_type'};
    my $new_value_types = $args{'value_types'};

    # determine all the cache ids for all these metadata value types
    my @cache_ids;

    foreach my $new_value_type ( @$new_value_types ) {

        # include this value type in its data type entry
        $self->data_types->{$data_type->name}->value_types->{$new_value_type} = {'description' => $new_value_type,
                                                                                 'units' => $new_value_type};

        my $cache_id = $self->_get_cache_id( type => $data_type->name,
                                             collection => 'metadata',
                                             identifier => $new_value_type );

        push( @cache_ids, $cache_id );
    }

    # consult our cache to see if any of them dont exists
    my $cache_results = $self->memcache->get_multi( @cache_ids );

    my $found_missing = 0;

    foreach my $cache_id ( @cache_ids ) {

        # cache hit
        next if ( $cache_results->{$cache_id} );

        # found a value type we've never seen before
        $found_missing = 1;
        last;
    }

    # no new value types found to update
    return if ( !$found_missing );

    # get metadata collection for this data type
    my $metadata_collection = $data_type->database->get_collection( 'metadata' );

    # get lock for this metadata document
    my $lock_id = $self->_get_lock_id( type => $data_type->name,
                                       collection => 'metadata' );

    my $lock = $self->locker->lock( $lock_id, LOCK_TIMEOUT );

    # grab the current metadata document
    my $doc = $metadata_collection->find_one( {}, {'values' => 1} );

    # error if there is none present
    if ( !$doc ) {

        $self->locker->release( $lock );

        die( 'No metadata document found for database ' . $data_type->name . '.' );
    }

    my $updates = {};

    # find any new value types
    foreach my $new_value_type ( @$new_value_types ) {

        # skip it if it already exists
        next if ( exists( $doc->{'values'}{$new_value_type} ) );

        $self->logger->debug( "Adding new value type $new_value_type to database " . $data_type->name . "." );

        # found a new one that needs to be added
        $updates->{"values.$new_value_type"} = {'description' => $new_value_type,
                                                'units' => $new_value_type};
    }

    # is there at least one update to perform?
    if ( keys( %$updates ) > 0 ) {

        # update the single metadata document with all new value types found
        $metadata_collection->update( {},
                                      {'$set' => $updates} );
    }

    # mark all value types in our cache
    my @multi = map { [$_ => 1] } @cache_ids;
    $self->memcache->set_multi( @multi );

    # all done, release our lock on this metadata document
    $self->locker->release( $lock );
}

sub _create_measurement_document {

    my ( $self, %args ) = @_;

    my $identifier = $args{'identifier'};
    my $data_type = $args{'data_type'};
    my $meta = $args{'meta'};
    my $start = $args{'start'};
    my $interval = $args{'interval'};

    $self->logger->debug( "Measurement $identifier in database " . $data_type->name . " not found in cache." );

    # get lock for this measurement identifier
    my $lock_id = $self->_get_lock_id( type => $data_type->name,
                                       collection => 'measurements',
                                       identifier => $identifier );

    my $lock = $self->locker->lock( $lock_id, LOCK_TIMEOUT );

    # get measurement collection for this data type
    my $measurement_collection = $data_type->database->get_collection( 'measurements' );

    # see if it exists in the database (and is active)
    my $query = Tie::IxHash->new( identifier => $identifier,
                                  end => undef );

    my $exists = $measurement_collection->count( $query );

    # doesn't exist yet
    if ( !$exists ) {

        $self->logger->debug( "Active measurement $identifier not found in database " . $data_type->name . ", adding." );

        my $metadata_fields = $data_type->metadata_fields;

        my $fields = Tie::IxHash->new( identifier => $identifier,
                                       start => $start + 0,
                                       end => undef,
                                       last_updated => $start + 0 );

        while ( my ( $field, $value ) = each( %$meta ) ) {

            # skip it if its not a required meta field for this data type, the writer should only ever set those
            next if ( !$metadata_fields->{$field}{'required'} );

            $fields->Push( $field => $value );
        }

        # create it
        $measurement_collection->insert( $fields );
    }

    # mark it in our known cache so no one ever tries to add it again
    my $cache_id = $self->_get_cache_id( type => $data_type->name,
                                         collection => 'measurements',
                                         identifier => $identifier );

    my $cache_duration = MEASUREMENT_CACHE_EXPIRATION;

    # use longer cache duration for measurements not submitted often
    $cache_duration = $interval * 2 if ( $interval * 2 > $cache_duration );

    $self->memcache->set( $cache_id, 1, $interval * 2 );

    # release our lock on this measurement document
    $self->locker->release( $lock );
}

sub _fetch_data_types {

    my ( $self ) = @_;

    $self->logger->debug( 'Getting data types.' );

    my $data_types = {};

    # determine databases to ignore
    my $ignore_databases = {};

    $self->config->{'force_array'} = 1;
    my @ignore_databases = $self->config->get( '/config/ignore-databases/database' );
    $self->config->{'force_array'} = 0;

    foreach my $database ( @ignore_databases ) {

        $database = $database->[0];

        $self->logger->debug( "Ignoring database '$database'." );

        $ignore_databases->{$database} = 1;
    }

    # grab all database names in mongo
    my @database_names = $self->mongo_rw->database_names();

    foreach my $database ( @database_names ) {

        # skip it if its marked to be ignored
        next if ( $ignore_databases->{$database} || $database =~ /^_/ );

        $self->logger->debug( "Storing data type for database $database." );

        my $data_type;

        try {

            $data_type = GRNOC::TSDS::DataType->new( name => $database,
                                                     database => $self->mongo_rw->get_database( $database ) );
        }

        catch {

            $self->logger->warn( $_ );
        };

        next if !$data_type;

        # store this as one of our known data types
        $data_types->{$database} = $data_type;
    }

    # update the list of known data types
    $self->_set_data_types( $data_types );
}

sub _rabbit_connect {

    my ( $self ) = @_;

    my $rabbit_host = $self->config->get( '/config/rabbit/@host' );
    my $rabbit_port = $self->config->get( '/config/rabbit/@port' );
    my $rabbit_queue = $self->config->get( '/config/rabbit/@queue' );

    while ( 1 ) {

        $self->logger->info( "Connecting to RabbitMQ $rabbit_host:$rabbit_port." );

        my $connected = 0;

        try {

            my $rabbit = Net::AMQP::RabbitMQ->new();

            $rabbit->connect( $rabbit_host, {'port' => $rabbit_port} );
            $rabbit->channel_open( 1 );
            $rabbit->queue_declare( 1, $rabbit_queue, {'auto_delete' => 0} );
            $rabbit->basic_qos( 1, { prefetch_count => QUEUE_PREFETCH_COUNT } );
            $rabbit->consume( 1, $rabbit_queue, {'no_ack' => 0} );

            $self->_set_rabbit( $rabbit );

            $connected = 1;
        }

        catch {

            $self->logger->error( "Error connecting to RabbitMQ: $_" );
        };

        last if $connected;

        $self->logger->info( "Reconnecting after " . RECONNECT_TIMEOUT . " seconds..." );
        sleep( RECONNECT_TIMEOUT );
    }
}

1;
