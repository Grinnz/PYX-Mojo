package Game::PYX::Controller::Game;
use Mojo::Base 'Mojolicious::Controller';
use Mojo::JSON qw/decode_json encode_json/;

sub join_game {
	my $self = shift;
	$self->app->log->debug('WebSocket opened');
	$self->inactivity_timeout(300);
	my $game_id = $self->param('id');
	my $nick = $self->session->{nick} // 'Tester';
	$self->stash(game_id => $game_id);
	
	my $channel = "game:$game_id";
	
	$self->on(message => sub {
		my ($self, $msg) = @_;
		return $self->app->log->warn("Received invalid WebSocket message: $msg")
			unless my $msg_hash = decode_json $msg;
		
		my $cmd = $msg_hash->{cmd} // 'chat';
		if ($cmd eq 'chat') {
			$self->redis->publish($channel => encode_json { from => $nick, cmd => 'chat', msg => $msg_hash->{msg} });
		} elsif ($cmd eq 'join') {
			$self->redis->publish($channel => encode_json { from => $nick, cmd => 'join' });
		}
	});
	$self->on(finish => sub {
		my ($self, $code, $reason) = @_;
		$self->app->log->debug("WebSocket closed with status $code");
		$self->redis->publish($channel => encode_json { from => $nick, cmd => 'leave' });
	});
	
	my $redis = $self->redis;
	my $log = $self->app->log;
	$redis->on(message => sub {
		my ($redis, $msg, $channel) = @_;
		$self->send($msg);
	});
	$redis->subscribe(["game:$game_id"] => sub {
		my ($redis, $err) = @_;
		return $log->error($err) if $err;
		$redis->publish("game:$game_id" => encode_json { from => $nick, cmd => 'join' });
	});
}

1;

