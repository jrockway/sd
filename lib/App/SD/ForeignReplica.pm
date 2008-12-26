package App::SD::ForeignReplica;
use Moose;
use Params::Validate;

extends 'Prophet::ForeignReplica';

=head2 prophet_has_seen_transaction $transaction_id

Given an transaction id, will return true if this transaction originated in Prophet 
and was pushed to RT or originated in RT and has already been pulled to the prophet replica.

=cut

# This is a mapping of all the transactions we have pushed to the
# remote replica we'll only ever care about remote sequence #s greater
# than the last transaction # we've pulled from the remote replica
# once we've done a pull from the remote replica, we can safely expire
# all records of this type for the remote replica (they'll be
# obsolete)

# we use this cache to avoid integrating changesets we've pushed to the remote replica when doing a subsequent pull

my $TXN_METATYPE = 'txn-source';



sub integrate_change {
    my $self = shift;
    my ( $change, $changeset ) = validate_pos(
        @_,
        { isa => 'Prophet::Change' },
        { isa => 'Prophet::ChangeSet' }
    );

    # don't push internal records
    return if $change->record_type =~ /^__/;

    Prophet::App->require( $self->push_encoder());
    my $recoder = $self->push_encoder->new( { sync_source => $self } );
    $recoder->integrate_change($change,$changeset);
}



sub _txn_storage {
    my $self = shift;
    return $self->state_handle->metadata_storage( $TXN_METATYPE,
        'prophet-txn-source' );
}

sub prophet_has_seen_transaction {
    my $self = shift;
    my ($id) = validate_pos( @_, 1 );
    return $self->_txn_storage->( $self->uuid . '-txn-' . $id );
}

sub record_pushed_transaction {
    my $self = shift;
    my %args = validate( @_,
        { transaction => 1, changeset => { isa => 'Prophet::ChangeSet' } } );

    $self->_txn_storage->(
        $self->uuid . '-txn-' . $args{transaction},
        join( ':',
            $args{changeset}->original_source_uuid,
            $args{changeset}->original_sequence_no )
    );
}

sub traverse_changesets {
    my $self = shift;
    my %args = validate( @_,
        {   after    => 1,
            callback => 1,
        }
    );

    Prophet::App->require( $self->pull_encoder());
    my $recoder = $self->pull_encoder->new( { sync_source => $self } );
    $recoder->run(after => $args{'after'}, callback => $args{'callback'});

}

sub remote_uri_path_for_id {
    die "your subclass needds to implement this to be able to map a remote id to /ticket/id or soemthing";

}

sub uuid_for_remote_id {
    my ( $self, $id ) = @_;
    return $self->_lookup_uuid_for_remote_id($id)
        || $self->uuid_for_url(
        $self->remote_url . $self->remote_uri_path_for_id($id) );
}

sub _lookup_uuid_for_remote_id {
    my $self = shift;
    my ($id) = validate_pos( @_, 1 );

    return $self->_remote_id_storage(
        $self->uuid_for_url(
            $self->remote_url . $self->remote_uri_path_for_id($id)
        )
    );
}

sub _set_uuid_for_remote_id {
    my $self = shift;
    my %args = validate( @_, { uuid => 1, remote_id => 1 } );
    return $self->_remote_id_storage(
        $self->uuid_for_url(
                  $self->remote_url
                . $self->remote_uri_path_for_id( $args{'remote_id'} )
        ),
        $args{uuid}
    );
}

# This cache stores uuids for tickets we've synced from a remote RT
# Basically, if we created the ticket to begin with, then we'll know its uuid
# if we pulled the ticket from RT then its uuid will be generated based on a UUID-from-ticket-url scheme
# This cache is PERMANENT. - aka not a cache but a mapping table

sub remote_id_for_uuid {
    my ( $self, $uuid_or_luid ) = @_;

    my $ticket = Prophet::Record->new(
        handle => $self->app_handle->handle,
        type   => 'ticket'
    );
    $ticket->load( $uuid_or_luid =~ /^\d+$/? 'luid': 'uuid', $uuid_or_luid )
        or do {
            warn "couldn't load ticket #$uuid_or_luid";
            return undef
        };

    my $prop = $self->uuid . '-id';
    my $id = $ticket->prop( $prop )
        or warn "ticket #$uuid_or_luid has no property '$prop'";
    return $id;
}

sub _set_remote_id_for_uuid {
    my $self = shift;
    my %args = validate(
        @_,
        {   uuid      => 1,
            remote_id => 1
        }
    );

    my $ticket = Prophet::Record->new(
        handle => $self->app_handle->handle,
        type   => 'ticket'
    );
    $ticket->load( uuid => $args{'uuid'} );
    $ticket->set_props( props => { $self->uuid.'-id' => $args{'remote_id'} } );

}


# XXX TODO, rename this
sub record_pushed_ticket {
    my $self = shift;
    my %args = validate(
        @_,
        {   uuid      => 1,
            remote_id => 1
        }
    );
    $self->_set_uuid_for_remote_id(%args);
    $self->_set_remote_id_for_uuid(%args);
}

__PACKAGE__->meta->make_immutable;
no Moose;

1;
