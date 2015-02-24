package Game::PYX::Controller::Game;
use Mojo::Base 'Mojolicious::Controller';
use Mojo::IOLoop;
use Mojo::JSON qw/decode_json encode_json false true/;
use Mojo::Util 'md5_sum';
use List::Util 'shuffle';
use Scalar::Util 'weaken';

use constant GAME_EXPIRE_SECONDS => 3600;
use constant {
	GAME_STATUS_UNSTARTED => 'unstarted',
	GAME_STATUS_TURN_PICK => 'turn_pick',
	GAME_STATUS_TURN_JUDGE => 'turn_judge',
	GAME_STATUS_TURN_WAIT => 'turn_wait',
};

sub connect {
	my $self = shift;
	$self->app->log->debug('WebSocket opened');
	$self->inactivity_timeout(30);
	
	$self->on(message => \&on_ws_message);
	$self->on(finish => \&on_ws_close);
	
	weaken $self;
	Mojo::IOLoop->singleton->on(finish => sub { $self->loop_finish });
}

sub loop_finish {
	my $self = shift;
	$self->finish(1001 => 'Server exiting');
}

my %ws_dispatch = (
	set_userid => 'ws_set_userid',
	set_nick => 'ws_set_nick',
	chat => 'ws_chat',
	join_game => 'ws_join_game',
	start_game => 'ws_start_game',
	game_state => 'ws_game_state',
	card_data => 'ws_card_data',
	heartbeat => undef,
);

sub on_ws_message {
	my ($self, $msg) = @_;
	my $nick = $self->stash->{nick};
	return $self->app->log->warn("Received invalid WebSocket message from $nick: $msg")
		unless my $msg_hash = eval { decode_json $msg };
	
	my $action = $msg_hash->{action} // 'unknown';
	if (exists $ws_dispatch{$action}) {
		my $method = $ws_dispatch{$action} // return;
		return $self->$method($msg_hash);
	} else {
		return $self->app->log->warn("Received unknown WebSocket action from $nick: $action");
	}
}

sub ws_set_userid {
	my ($self, $msg_hash) = @_;
	my $userid = $msg_hash->{userid};
	if (defined $userid and $self->redis->exists("user:$userid")) { # Existing user
		$self->send(encode_json { action => 'user_data', user => $self->user_data($userid) });
	} else { # New user
		$userid = md5_sum $self->tx->remote_address . '$' . rand . '$' . time;
		$self->redis->hset("user:$userid", exists => 1);
		$self->send(encode_json { action => 'set_userid', userid => $userid });
	}
	$self->stash->{userid} = $userid;
}

sub ws_set_nick {
	my ($self, $msg_hash) = @_;
	my $nick = $msg_hash->{nick};
	my $userid = $self->stash->{userid};
	$self->redis->hset("user:$userid", nick => $nick);
	$self->stash->{nick} = $nick;
	$self->send(encode_json { action => 'confirm_nick', confirmed => true, nick => $nick });
}

sub ws_chat {
	my ($self, $msg_hash) = @_;
	my $nick = $self->stash->{nick};
	my $game = $msg_hash->{game} // return;
	my $msg = $msg_hash->{msg};
	$self->app->log->debug("[$game] <$nick> $msg");
	$self->redis->publish("game:$game" => encode_json {
		game => $game, from => $nick, action => 'chat', msg => $msg, time => time
	});
}

sub ws_join_game {
	my ($self, $msg_hash) = @_;
	my $nick = $self->stash->{nick};
	my $game = $msg_hash->{game};
	$self->join_game($game);
}

sub ws_start_game {
	my ($self, $msg_hash) = @_;
	my $nick = $self->stash->{nick};
	my $game = $msg_hash->{game};
	my ($host, $status) = @{$self->redis->hmget("game:$game", 'host', 'status')};
	return $self->app->log->warn("$nick tried to start game $game, but it is already in progress")
		unless $status eq GAME_STATUS_UNSTARTED;
	return $self->app->log->warn("$nick tried to start game $game, but is not the host")
		unless defined $host and $host eq $nick;
	$self->start_game;
}

sub ws_game_state {
	my ($self, $msg_hash) = @_;
	my $game = $msg_hash->{game};
	$self->send(encode_json { game => $game, action => 'game_state', state => $self->game_state($game) });
}

sub ws_card_data {
	my ($self, $msg_hash) = @_;
	my $black_cards = $msg_hash->{cards}{black} // [];
	my $white_cards = $msg_hash->{cards}{white} // [];
	$self->send(encode_json { action => 'card_data',
		cards => $self->card_data($black_cards, $white_cards) });
}

sub on_ws_close {
	my ($self, $code, $reason) = @_;
	my $nick = $self->stash->{nick};
	$self->app->log->debug("WebSocket for $nick closed with status $code");
	my $redis = $self->redis;
	my $games = $redis->smembers("user:$nick:games");
	foreach my $game (@$games) {
		$redis->publish("game:$game" => encode_json { game => $game, from => $nick, action => 'disconnect', time => time });
	}
	$redis->unsubscribe($games);
}

sub on_redis_message {
	my ($self, $redis, $msg, $channel) = @_;
	my $nick = $self->stash->{nick};
	return $self->app->log->warn("Received invalid Redis message for $nick: $msg")
		unless my $msg_hash = eval { decode_json $msg };
	my $action = $msg_hash->{action} // 'unknown';
	my $game = $msg_hash->{game};
	if ($action eq 'chat' or $action eq 'join' or $action eq 'leave') {
		$self->send($msg);
	} elsif ($action eq 'start_turn') {
		$self->send(encode_json { game => $game, action => 'game_state', state => $self->game_state });
	} else {
		$self->app->log->warn("Received unknown Redis action for $nick: $action");
	}
}

sub user_data {
	my ($self, $userid) = @_;
	my $nick = $self->redis->hget("user:$userid", 'nick');
	$self->stash->{nick} = $nick;
	return { nick => $nick };
}

sub join_game {
	my ($self, $game) = @_;
	my $redis = $self->redis;
	my $nick = $self->stash->{nick};
	$redis->on(message => sub { $self->on_redis_message(@_) });
	$redis->subscribe(["game:$game"] => sub {
		my ($redis, $err) = @_;
		return $self->app->log->error($err) if $err;
		$redis->publish("game:$game" =>
			encode_json { game => $game, from => $nick, action => 'join', time => time });
	});
	
	$redis->hsetnx("game:$game", host => $nick);
	$redis->hsetnx("game:$game", status => 'unstarted');
	$redis->rpush("game:$game:players", $nick);
	$self->set_expires($game);
	$self->send(encode_json { action => 'confirm_join', confirmed => true, game => $game });
}

sub game_state {
	my ($self, $game) = @_;
	my $redis = $self->redis;
	my $nick = $self->stash->{nick};
	my ($host, $status, $czar, $black_card)
		= @{$self->redis->hmget("game:$game", 'host', 'status', 'czar', 'black_card')};
	my $players = $redis->lrange("game:$game:players", 0, -1);
	my $is_czar = $players->[$czar] eq $nick ? true : false;
	foreach my $player (@$players) {
		my ($score) = @{$redis->hmget("game:$game:players:$player", 'score')};
		$player = { nick => $player, score => $score, is_czar => false };
	}
	$players->[$czar]{is_czar} = true;
	my $hand = $redis->lrange("game:$game:players:$nick:hand", 0, -1);
	@$hand = reverse @$hand; # hand stored in reverse for rpoplpush
	return { host => $host, status => $status, black_card => $black_card, players => $players,
		hand => $hand, is_czar => $is_czar };
}

sub card_data {
	my ($self, $black_cards, $white_cards) = @_;
	my $redis = $self->redis;
	my %cards = (white => {}, black => {});
	foreach my $id (@$black_cards) {
		my ($text, $draw, $pick, $watermark)
			= @{$redis->hmget("black_card:$id", 'text', 'draw', 'pick', 'watermark')};
		$cards{black}{$id} = { text => $text, draw => $draw, pick => $pick, watermark => $watermark };
	}
	foreach my $id (@$white_cards) {
		my ($text, $watermark) = @{$redis->hmget("white_card:$id", 'text', 'watermark')};
		$cards{white}{$id} = { text => $text, watermark => $watermark };
	}
	return \%cards;
}

sub remove_player {
	my ($self, $game, $nick) = @_;
	my $redis = $self->redis;
	$redis->lrem("game:$game:players", 0, $nick);
	my $hand = $redis->lrange("game:$game:players:$nick:hand", 0, -1);
	$redis->del("game:$game:players:$nick:hand");
	$redis->lpush("game:$game:discard_white", @$hand) if @$hand;
	my $host = $redis->hget("game:$game", 'host');
	if ($nick eq $host) {
		my $new_host = $redis->lindex("game:$game:players", 0);
		if (defined $new_host) {
			$redis->hset("game:$game", host => $new_host);
		} else {
			$redis->hdel("game:$game", 'host');
		}
	}
	$redis->set_expires($game);
}

sub start_game {
	my ($self, $game) = @_;
	my $redis = $self->redis;
	
	# TODO: game options
	my @sets = qw/1151 1152 100211 1155 1256 100154 100415 100257 1153 1154 1488
		100422 100049 100050 100051 100312 100485 100560 100532 100531 100017/;
	my (%white_cards, %black_cards);
	$white_cards{$_} = 1 for map { @{$redis->smembers("card_set:$_:white_cards")} } @sets;
	$black_cards{$_} = 1 for map { @{$redis->smembers("card_set:$_:black_cards")} } @sets;
	my @white_cards = shuffle keys %white_cards;
	my @black_cards = shuffle keys %black_cards;
	
	my $players = $redis->lrange("game:$game:players", 0, -1);
	my $hand_size = 7;
	my @to_deal = splice @white_cards, 0, $hand_size * @$players;
	foreach my $i (0..(@$players-1)) {
		my $player = $players->[$i];
		my @hand = map { $to_deal[$i + $_ * @$players] } 0..($hand_size-1);
		$redis->del("game:$game:players:$player:hand");
		$redis->lpush("game:$game:players:$player:hand", @hand);
	}
	
	$redis->del("game:$game:draw_white", "game:$game:draw_black", "game:$game:discard_white", "game:$game:discard_black");
	$redis->lpush("game:$game:draw_white", @white_cards);
	$redis->lpush("game:$game:draw_black", @black_cards);
	
	$redis->hset("game:$game", status => 'playing');
	$redis->hdel("game:$game", 'czar');
	$self->start_turn($game);
}

sub start_turn {
	my ($self, $game) = @_;
	my $redis = $self->redis;
	
	my $num_players = $redis->llen("game:$game:players");
	my $czar = $redis->hget("game:$game", 'czar');
	$czar = defined $czar ? $czar+1 : 0;
	$czar = 0 if $czar >= $num_players;
	$redis->hset("game:$game", czar => $czar);
	
	my $black_card = $redis->rpop("game:$game:draw_black");
	unless (defined $black_card) {
		$self->shuffle_discard_black($game);
		$black_card = $redis->rpop("game:$game:draw_black");
	}
	
	$redis->hset("game:$game", black_card => $black_card);
	my $draw = $redis->hget("black_card:$black_card", 'draw') // 0;
	$self->draw_white_cards($game, $draw) if $draw > 0;
	
	$self->set_expires($game);
	
	$redis->publish("game:$game" => encode_json { game => $game, action => 'start_turn' });
}

sub draw_white_cards {
	my ($self, $game, $draw) = @_;
	return unless $draw > 0;
	my $redis = $self->redis;
	
	my $players = $redis->lrange("game:$game:players", 0, -1);
	foreach my $player (@$players) {
		foreach my $i (1..$draw) {
			my $drawn = $redis->rpoplpush("game:$game:draw_white", "game:$game:players:$player:hand");
			unless (defined $drawn) {
				$self->shuffle_discard_white($game);
				$redis->rpoplpush("game:$game:draw_white", "game:$game:players:$player:hand");
			}
		}
	}
}

sub shuffle_discard_black {
	my ($self, $game) = @_;
	my $redis = $self->redis;
	
	my $black_cards = $redis->lrange("game:$game:discard_black");
	$redis->del("game:$game:discard_black");
	$redis->lpush("game:$game:draw_black", shuffle @$black_cards);
}

sub shuffle_discard_white {
	my ($self, $game) = @_;
	my $redis = $self->redis;
	
	my $white_cards = $redis->lrange("game:$game:discard_white");
	$redis->del("game:$game:discard_white");
	$redis->lpush("game:$game:draw_white", shuffle @$white_cards);
}

sub set_expires {
	my ($self, $game) = @_;
	my $redis = $self->redis;
	my $nick = $self->stash->{nick};
	$redis->expire("game:$game" => GAME_EXPIRE_SECONDS);
	$redis->expire("game:$game:players" => GAME_EXPIRE_SECONDS);
	$redis->expire("game:$game:draw_white" => GAME_EXPIRE_SECONDS);
	$redis->expire("game:$game:draw_black" => GAME_EXPIRE_SECONDS);
	$redis->expire("game:$game:discard_white" => GAME_EXPIRE_SECONDS);
	$redis->expire("game:$game:discard_black" => GAME_EXPIRE_SECONDS);
	$redis->expire("game:$game:played_white" => GAME_EXPIRE_SECONDS);
	$redis->expire("game:$game:players:$nick" => GAME_EXPIRE_SECONDS);
	$redis->expire("game:$game:players:$nick:hand" => GAME_EXPIRE_SECONDS);
}

1;
