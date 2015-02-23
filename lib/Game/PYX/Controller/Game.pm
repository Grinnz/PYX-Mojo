package Game::PYX::Controller::Game;
use Mojo::Base 'Mojolicious::Controller';
use Mojo::IOLoop;
use Mojo::JSON qw/decode_json encode_json false true/;
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
	} elsif ($action eq 'game_state') {
		$self->send(encode_json { action => 'game_state', state => $self->game_state });
	} elsif ($action eq 'card_data') {
		my $black_cards = $msg_hash->{cards}{black} // [];
		my $white_cards = $msg_hash->{cards}{white} // [];
		$self->send(encode_json { action => 'card_data',
			cards => $self->card_data($black_cards, $white_cards) });
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
	$self->remove_player($nick);
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
	} elsif ($action eq 'start_turn') {
		$self->send(encode_json { action => 'game_state', state => $self->game_state });
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
	my $state = $self->redis->hmget($channel, 'host', 'status', 'czar', 'black_card');
	my ($host, $status, $czar, $black_card) = @$state;
	my $players = $redis->lrange("$channel:players", 0, -1);
	my $is_czar = $players->[$czar] eq $nick ? true : false;
	foreach my $player (@$players) {
		my $attrs = $redis->hmget("$channel:players:$player", 'score');
		my ($score) = @$attrs;
		$player = { nick => $player, score => $score, is_czar => false };
	}
	$players->[$czar]{is_czar} = true;
	my $hand = $redis->lrange("$channel:players:$nick:hand", 0, -1);
	@$hand = reverse @$hand; # hand stored in reverse for rpoplpush
	return { host => $host, status => $status, black_card => $black_card, players => $players,
		hand => $hand, is_czar => $is_czar };
}

sub card_data {
	my ($self, $black_cards, $white_cards) = @_;
	my $redis = $self->redis;
	my %cards = (white => {}, black => {});
	foreach my $id (@$black_cards) {
		my $attrs = $redis->hmget("black_card:$id", 'text', 'draw', 'pick', 'watermark');
		my ($text, $draw, $pick, $watermark) = @$attrs;
		$cards{black}{$id} = { text => $text, draw => $draw, pick => $pick, watermark => $watermark };
	}
	foreach my $id (@$white_cards) {
		my $attrs = $redis->hmget("white_card:$id", 'text', 'watermark');
		my ($text, $watermark) = @$attrs;
		$cards{white}{$id} = { text => $text, watermark => $watermark };
	}
	return \%cards;
}

sub remove_player {
	my ($self, $nick) = @_;
	my $redis = $self->redis;
	my $channel = $self->stash('channel');
	$redis->lrem("$channel:players", 0, $nick);
	my $hand = $redis->lrange("$channel:players:$nick:hand", 0, -1);
	$redis->del("$channel:players:$nick:hand");
	$redis->lpush("$channel:discard_white", @$hand) if @$hand;
	my $host = $redis->hget($channel, 'host');
	if ($nick eq $host) {
		my $new_host = $redis->lindex("$channel:players", 0);
		if (defined $new_host) {
			$redis->hset($channel, host => $new_host);
		} else {
			$redis->hdel($channel, 'host');
		}
	}
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
	
	my $players = $redis->lrange("$channel:players", 0, -1);
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
	
	$redis->hset($channel, status => 'playing');
	$redis->hdel($channel, 'czar');
	$self->start_turn;
}

sub start_turn {
	my $self = shift;
	my $redis = $self->redis;
	my $channel = $self->stash('channel');
	
	my $num_players = $redis->llen("$channel:players");
	my $czar = $redis->hget($channel, 'czar');
	$czar = defined $czar ? $czar+1 : 0;
	$czar = 0 if $czar >= $num_players;
	$redis->hset($channel, czar => $czar);
	
	my $black_card = $redis->rpop("$channel:draw_black");
	unless (defined $black_card) {
		$self->shuffle_discard_black;
		$black_card = $redis->rpop("$channel:draw_black");
	}
	
	$redis->hset($channel, black_card => $black_card);
	my $draw = $redis->hget("black_card:$black_card", 'draw') // 0;
	$self->draw_white_cards($draw) if $draw > 0;
	
	$self->set_expires;
	
	$redis->publish($channel => encode_json { action => 'start_turn' });
}

sub draw_white_cards {
	my ($self, $draw) = @_;
	return unless $draw > 0;
	my $redis = $self->redis;
	my $channel = $self->stash('channel');
	
	my $players = $redis->lrange("$channel:players", 0, -1);
	foreach my $player (@$players) {
		foreach my $i (1..$draw) {
			my $drawn = $redis->rpoplpush("$channel:draw_white", "$channel:players:$player:hand");
			unless (defined $drawn) {
				$self->shuffle_discard_white;
				$redis->rpoplpush("$channel:draw_white", "$channel:players:$player:hand");
			}
		}
	}
}

sub shuffle_discard_black {
	my $self = shift;
	my $redis = $self->redis;
	my $channel = $self->stash('channel');
	
	my $black_cards = $redis->lrange("$channel:discard_black");
	$redis->del("$channel:discard_black");
	$redis->lpush("$channel:draw_black", shuffle @$black_cards);
}

sub shuffle_discard_white {
	my $self = shift;
	my $redis = $self->redis;
	my $channel = $self->stash('channel');
	
	my $white_cards = $redis->lrange("$channel:discard_white");
	$redis->del("$channel:discard_white");
	$redis->lpush("$channel:draw_white", shuffle @$white_cards);
}

1;
