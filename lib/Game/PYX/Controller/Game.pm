package Game::PYX::Controller::Game;
use Mojo::Base 'Mojolicious::Controller';
use Mojo::IOLoop;
use Mojo::JSON qw/decode_json encode_json/;
use List::Util 'shuffle';
use Scalar::Util 'weaken';

use constant GAME_EXPIRE_SECONDS => 3600;

sub join_game {
	my $self = shift;
	$self->app->log->debug('WebSocket opened');
	$self->inactivity_timeout(30);
	my $game_id = $self->param('id');
	$self->stash(game_id => $game_id);
	my $channel = "game:$game_id";
	$self->stash(channel => $channel);
	my $nick = $self->session->{nick} // 'Tester';
	$self->stash(nick => $nick);
	
	weaken $self;
	Mojo::IOLoop->singleton->on(finish => sub { $self->loop_finish });
	
	$self->on(message => \&ws_message);
	$self->on(finish => \&ws_close);
	
	my $redis = $self->redis;
	$redis->on(message => sub { $self->redis_message(@_) });
	$redis->subscribe([$channel] => sub { $self->redis_subscribe(@_) });
	
	$redis->hsetnx($channel, host => $nick);
	$redis->hsetnx($channel, status => 'unstarted');
	$redis->rpush("$channel:players", $nick);
	$self->set_expires;
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
	} elsif ($action eq 'start') {
		my $host = $self->redis->hget($channel, 'host');
		return $self->app->log->warn("$nick tried to start the game, but is not the host")
			unless defined $host and $host eq $nick;
		$self->start_game;
	}
}

sub ws_close {
	my ($self, $code, $reason) = @_;
	$self->app->log->debug("WebSocket closed with status $code");
	my $channel = $self->stash('channel');
	my $nick = $self->stash('nick');
	my $redis = $self->redis;
	$redis->publish($channel => encode_json { from => $nick, action => 'leave', time => time });
	$redis->unsubscribe([$channel]);
	$redis->lrem("$channel:players", 0, $nick);
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
	return $self->app->log->warn("Received invalid Redis message: $msg")
		unless my $msg_hash = eval { decode_json $msg };
	my $action = $msg_hash->{action} // 'chat';
	if ($action eq 'chat' or $action eq 'join' or $action eq 'leave') {
		$self->send($msg);
	} elsif ($action eq 'start') {
		$self->send(encode_json { action => 'state', state => $self->game_state });
	}
}

sub loop_finish {
	my $self = shift;
	$self->finish(1001 => 'Server exiting');
}

sub set_expires {
	my $self = shift;
	my $channel = $self->stash('channel');
	my $nick = $self->stash('nick');
	my $redis = $self->redis;
	$redis->expire($channel => GAME_EXPIRE_SECONDS);
	$redis->expire("$channel:players" => GAME_EXPIRE_SECONDS);
	$redis->expire("$channel:draw_white" => GAME_EXPIRE_SECONDS);
	$redis->expire("$channel:draw_black" => GAME_EXPIRE_SECONDS);
	$redis->expire("$channel:discard_white" => GAME_EXPIRE_SECONDS);
	$redis->expire("$channel:discard_black" => GAME_EXPIRE_SECONDS);
	$redis->expire("$channel:played_white" => GAME_EXPIRE_SECONDS);
	$redis->expire("$channel:players:$nick" => GAME_EXPIRE_SECONDS);
	$redis->expire("$channel:players:$nick:hand" => GAME_EXPIRE_SECONDS);
}

sub game_state {
	my $self = shift;
	my $redis = $self->redis;
	my $channel = $self->stash('channel');
	my $nick = $self->stash('nick');
	my $state = $self->redis->hmget($channel, 'host', 'status', 'czar');
	my ($host, $status, $czar) = @$state;
	my $players = $redis->lrange("$channel:players", 0, -1);
	foreach my $player (@$players) {
		my $attrs = $redis->hmget("$channel:players:$player", 'score');
		my ($score) = @$attrs;
		$player = { nick => $player, score => $score };
	}
	my $hand = $redis->lrange("$channel:players:$nick:hand");
	return { host => $host, status => $status, czar => $czar, players => $players, hand => $hand };
}

sub start_game {
	my $self = shift;
	my $redis = $self->redis;
	my $channel = $self->stash('channel');
	
	# TODO: game options
	my @sets = qw/1151 1152 100211 1155 1256 100154 100415 100257 1153 1154 1488
		100422 100049 100050 100051 100312 100485 100560 100532 100531 100017/;
	my (%white_cards, %black_cards);
	$white_cards{$_} = 1 for map { @{$redis->smembers("card_set:$_:white_cards")} } @sets;
	$black_cards{$_} = 1 for map { @{$redis->smembers("card_set:$_:black_cards")} } @sets;
	my @white_cards = shuffle keys %white_cards;
	my @black_cards = shuffle keys %black_cards;
	
	my $players = $self->redis->lrange("$channel:players", 0, -1);
	my $hand_size = 7;
	my @to_deal = splice @white_cards, 0, $hand_size * @$players;
	foreach my $i (0..(@$players-1)) {
		my $player = $players->[$i];
		my @hand = map { $to_deal[$i + $_ * @$players] } 0..($hand_size-1);
		$redis->del("$channel:players:$player:hand");
		$redis->lpush("$channel:players:$player:hand", @hand);
	}
	
	$redis->del("$channel:draw_white", "$channel:draw_black", "$channel:discard_white", "$channel:discard_black");
	$redis->lpush("$channel:draw_white", @white_cards);
	$redis->lpush("$channel:draw_black", @black_cards);
	
	$redis->hmset($channel, status => 'playing', czar => 0);
	$self->start_turn;
}

sub start_turn {
	my $self = shift;
	my $redis = $self->redis;
	my $channel = $self->stash('channel');
	
	my $black_card = $redis->rpop("$channel:draw_black");
	unless (defined $black_card) {
		$self->shuffle_discard_black;
		$black_card = $redis->rpop("$channel:draw_black");
	}
	
	$redis->hset($channel, black_card => $black_card);
	$self->set_expires;
	
	$redis->publish($channel => encode_json { action => 'turn' });
}

sub shuffle_discard_black {
	my $self = shift;
	my $redis = $self->redis;
	my $channel = $self->stash('channel');
	
	my $black_cards = $redis->lrange("$channel:discard_black");
	$redis->del("$channel:discard_black");
	@$black_cards = shuffle @$black_cards;
	$redis->lpush("$channel:draw_black", @$black_cards);
}

sub shuffle_discard_white {
	my $self = shift;
	my $redis = $self->redis;
	my $channel = $self->stash('channel');
	
	my $white_cards = $redis->lrange("$channel:discard_white");
	$redis->del("$channel:discard_white");
	@$white_cards = shuffle @$white_cards;
	$redis->lpush("$channel:draw_white", @$white_cards);
}

1;

