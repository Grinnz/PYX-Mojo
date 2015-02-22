package Game::PYX::Controller::Game;
use Mojo::Base 'Mojolicious::Controller';
use Mojo::IOLoop;
use Mojo::JSON qw/decode_json encode_json/;
use Scalar::Util 'weaken';

sub join_game {
	my $self = shift;
	$self->app->log->debug('WebSocket opened');
	$self->inactivity_timeout(30);
	my $game_id = $self->param('id');
	$self->stash(game_id => $game_id);
	my $channel = "game:$game_id";
	$self->stash(channel => $channel);
	$self->stash(nick => $self->session->{nick} // 'Tester');
	
	Mojo::IOLoop->singleton->on(finish => sub { $self->loop_finish });
	
	$self->on(message => \&ws_message);
	$self->on(finish => \&ws_close);
	
	weaken $self;
	$self->redis->on(message => sub { $self->redis_message(@_) });
	$self->redis->subscribe([$channel] => sub { $self->redis_subscribe(@_) });
}

sub ws_message {
	my ($self, $msg) = @_;
	return $self->app->log->warn("Received invalid WebSocket message: $msg")
		unless my $msg_hash = eval { decode_json $msg };
	
	my $channel = $self->stash('channel');
	my $nick = $self->stash('nick');
	my $action = $msg_hash->{action} // 'chat';
	if ($action eq 'chat') {
		$self->redis->publish($channel => encode_json {
			from => $nick, action => 'chat', msg => $msg_hash->{msg}, time => time
		});
	}
}

sub ws_close {
	my ($self, $code, $reason) = @_;
	$self->app->log->debug("WebSocket closed with status $code");
	my $channel = $self->stash('channel');
	my $nick = $self->stash('nick');
	$self->redis->publish($channel => encode_json { from => $nick, action => 'leave', time => time });
	$self->redis->unsubscribe([$channel]);
}

sub redis_subscribe {
	my ($self, $redis, $err) = @_;
	return $self->app->log->error($err) if $err;
	my $channel = $self->stash('channel');
	my $nick = $self->stash('nick');
	$redis->publish($channel => encode_json { from => $nick, action => 'join', time => time });
}

sub redis_message {
	my ($self, $redis, $msg, $channel) = @_;
	return unless $channel eq $self->stash('channel');
	$self->send($msg);
}

sub loop_finish {
	my $self = shift;
	$self->finish(1001 => 'Server exiting');
}

1;

