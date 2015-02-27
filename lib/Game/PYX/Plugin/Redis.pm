package Game::PYX::Plugin::Redis;
use Mojo::Base 'Mojolicious::Plugin';
use Mojo::JSON qw/decode_json encode_json false true/;
use Mojo::Redis2;
use POSIX;
use List::MoreUtils 'first_index';
use List::Util 'shuffle';
use Scalar::Util 'weaken';

use constant GAME_EXPIRE_SECONDS => 3600;

sub register {
	my ($self, $app) = @_;
	
	$app->helper($_ => $self->can("_$_")) for qw/
		redis backend_publish clear_backend
		user_exists set_user_exists set_user_nick user_data user_games
		game_list game_exists game_state game_host game_status
		gather_cards card_data init_game subscribe_to_game unsubscribe_from_games
		add_game_player remove_game_player
		game_player_count game_players set_game_host
		shuffle_discard_black shuffle_discard_white
		draw_black_card black_card_draw_count draw_white_cards draw_white_card
		clear_hands deal_to_players set_game_started set_next_czar set_expires/;
}

sub _redis {
	my $c = shift;
	my $redis = $c->stash('pyx.redis');
	unless (defined $redis) {
		my $url = $c->config('redis_url');
		$c->stash('pyx.redis' => ($redis = defined $url
			? Mojo::Redis2->new(url => $url) : Mojo::Redis2->new));
		weaken $c;
		$redis->on(message => sub {
			my ($redis, $msg, $channel) = @_;
			my $nick = $c->stash->{nick};
			return $c->app->log->warn("Received invalid Redis message for $nick: [$channel] $msg")
				unless my $data = eval { decode_json $msg };
			$c->app->log->debug("Received Redis message for $nick: [$channel] $msg");
			$c->on_backend_message($data, $channel);
		});
	}
	return $redis;
}

sub _backend_publish {
	my ($c, $channel, $data) = @_;
	$c->redis->publish($channel => encode_json $data);
}

sub _clear_backend {
	my $c = shift;
	delete $c->stash->{'pyx.redis'};
}

sub _user_exists {
	my ($c, $userid) = @_;
	return $c->redis->exists("user:$userid");
}

sub _set_user_exists {
	my ($c, $userid) = @_;
	$c->redis->hset("user:$userid", exists => 1);
}

sub _set_user_nick {
	my ($c, $nick) = @_;
	my $userid = $c->stash->{userid};
	$c->redis->hset("user:$userid", nick => $nick);
}

sub _user_data {
	my $c = shift;
	my $userid = $c->stash->{userid};
	my $nick = $c->redis->hget("user:$userid", 'nick');
	$c->stash->{nick} = $nick;
	return { nick => $nick };
}

sub _user_games {
	my $c = shift;
	my $userid = $c->stash->{userid};
	return $c->redis->smembers("user:$userid:games");
}

sub _game_list {
	my $c = shift;
	my $redis = $c->redis;
	my $games = $redis->smembers("games");
	foreach my $game (@$games) {
		my $num_players = $redis->llen("game:$game:players") // 0;
		$game = { name => $game, players => $num_players, joinable => true };
	}
	return $games;
}

sub _game_exists {
	my ($c, $game) = @_;
	return $c->redis->exists("game:$game");
}

sub _game_state {
	my ($c, $game) = @_;
	my $redis = $c->redis;
	my $userid = $c->stash->{userid};
	
	my ($host, $status, $czar, $black_card)
		= @{$redis->hmget("game:$game", 'host', 'status', 'czar', 'black_card')};
	my $players = $redis->lrange("game:$game:players", 0, -1);
	
	foreach my $player (@$players) {
		my ($pnick, $score) = @{$redis->hmget("game:$game:players:$player", 'nick', 'score')};
		my $is_czar = $czar eq $player ? true : false;
		my $is_host = $host eq $player ? true : false;
		$player = { nick => $pnick, score => $score, is_czar => $is_czar, is_host => $is_host };
	}
	
	my $is_czar = $czar eq $userid ? true : false;
	my $is_host = $host eq $userid ? true : false;
	my $hand = $redis->lrange("game:$game:players:$userid:hand", 0, -1);
	@$hand = reverse @$hand; # hand stored in reverse for rpoplpush
	return { status => $status, black_card => $black_card, players => $players,
		hand => $hand, is_czar => $is_czar, is_host => $is_host };
}

sub _game_host {
	my ($c, $game) = @_;
	return $c->redis->hget("game:$game", 'host');
}

sub _game_status {
	my ($c, $game) = @_;
	return $c->redis->hget("game:$game", 'status');
}

sub _gather_cards {
	my ($c, $sets) = @_;
	my $redis = $c->redis;
	my (%white_cards, %black_cards);
	$white_cards{$_} = 1 for map { @{$redis->smembers("card_set:$_:white_cards")} } @$sets;
	$black_cards{$_} = 1 for map { @{$redis->smembers("card_set:$_:black_cards")} } @$sets;
	my @white_cards = shuffle keys %white_cards;
	my @black_cards = shuffle keys %black_cards;
	return {white => \@white_cards, black => \@black_cards};
}

sub _card_data {
	my ($c, $black_cards, $white_cards) = @_;
	my $redis = $c->redis;
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

sub _init_game {
	my ($c, $game) = @_;
	my $redis = $c->redis;
	my $userid = $c->stash->{userid};
	$redis->sadd("games", $game);
	$redis->hsetnx("game:$game", host => $userid);
	$redis->hsetnx("game:$game", status => 'unstarted');
	return 1;
}

sub _subscribe_to_game {
	my ($c, $game) = @_;
	my $nick = $c->stash->{nick};
	$c->redis->subscribe(["game:$game"] => sub {
		my ($redis, $err) = @_;
		return $c->app->log->error($err) if $err;
		$redis->publish("game:$game" =>
			encode_json { game => $game, from => $nick, action => 'user_join', time => time });
	});
	return 1;
}

sub _unsubscribe_from_games {
	my ($c, $games) = @_;
	$games = [$games] unless ref $games eq 'ARRAY';
	$_ = "game:$_" for @$games;
	$c->redis->unsubscribe($games) if @$games;
}

sub _add_game_player {
	my ($c, $game, $userid) = @_;
	my $redis = $c->redis;
	$redis->rpush("game:$game:players", $userid);
	$redis->sadd("user:$userid:games", $game);
	return 1;
}

sub _remove_game_player {
	my ($c, $game, $userid) = @_;
	my $redis = $c->redis;
	$redis->lrem("game:$game:players", 0, $userid);
	my $hand = $redis->lrange("game:$game:players:$userid:hand", 0, -1);
	$redis->del("game:$game:players:$userid:hand");
	$redis->lpush("game:$game:discard_white", @$hand) if @$hand;
	my $host = $redis->hget("game:$game", 'host');
	$c->set_game_host($game) if $host eq $userid;
	return 1;
}

sub _game_player_count {
	my ($c, $game) = @_;
	return $c->redis->llen("game:$game:players");
}

sub _game_players {
	my ($c, $game) = @_;
	return $c->redis->lrange("game:$game:players", 0, -1);
}

sub _set_game_host {
	my ($c, $game) = @_;
	my $redis = $c->redis;
	if (defined (my $host = $redis->lindex("game:$game:players", 0))) {
		$redis->hset("game:$game", host => $host);
	} else {
		$redis->hdel("game:$game", 'host');
	}
	return 1;
}

sub _shuffle_discard_black {
	my ($c, $game) = @_;
	my $redis = $c->redis;
	my $black_cards = $redis->lrange("game:$game:discard_black", 0, -1);
	$redis->del("game:$game:discard_black");
	$redis->lpush("game:$game:draw_black", shuffle @$black_cards);
}

sub _shuffle_discard_white {
	my ($c, $game) = @_;
	my $redis = $c->redis;
	my $white_cards = $redis->lrange("game:$game:discard_white", 0, -1);
	$redis->del("game:$game:discard_white");
	$redis->lpush("game:$game:draw_white", shuffle @$white_cards);
}

sub _draw_black_card {
	my ($c, $game) = @_;
	my $redis = $c->redis;
	my $black_card = $redis->rpop("game:$game:draw_black");
	unless (defined $black_card) {
		$c->shuffle_discard_black($game);
		$black_card = $redis->rpop("game:$game:draw_black");
	}
	$redis->hset("game:$game", black_card => $black_card);
	return $black_card;
}

sub _black_card_draw_count {
	my ($c, $card) = @_;
	return $c->redis->hget("black_card:$card", 'draw') // 0;
}

sub _draw_white_cards {
	my ($c, $game) = @_;
	my $redis = $c->redis;
	my $players = $c->game_players($game);
	$c->draw_white_card($game, $_) for @$players;
}

sub _draw_white_card {
	my ($c, $game, $player) = @_;
	my $redis = $c->redis;
	my $drawn = $redis->rpoplpush("game:$game:draw_white", "game:$game:players:$player:hand");
	unless (defined $drawn) {
		$c->shuffle_discard_white($game);
		$drawn = $redis->rpoplpush("game:$game:draw_white", "game:$game:players:$player:hand");
	}
	return $drawn;
}

sub _clear_hands {
	my ($c, $game, $players) = @_;
	my @hand_keys = map { "game:$game:players:$_:hand" } @$players;
	$c->redis->del(@hand_keys);
	return 1;
}

sub _deal_to_players {
	my ($c, $game, $players, $cards) = @_;
	return 1 unless @$players and @$cards;
	my $redis = $c->redis;
	my %hands;
	my $i = 0;
	foreach my $card (@$cards) {
		my $player = $players->[$i];
		my $hand = $hands{$player} //= [];
		push @$hand, $card;
		++$i;
		$i = 0 if $i >= @$players;
	}
	foreach my $player (@$players) {
		my $hand = $hands{$player} // [];
		$redis->lpush("game:$game:players:$player:hand", @$hand) if @$hand;
	}
	return 1;
}

sub _set_game_started {
	my ($c, $game, $black_cards, $white_cards) = @_;
	my $redis = $c->redis;
	$redis->del("game:$game:draw_black", "game:$game:discard_black", "game:$game:draw_white", "game:$game:discard_white");
	$redis->lpush("game:$game:draw_black", @$black_cards);
	$redis->lpush("game:$game:draw_white", @$white_cards);
	$redis->hset("game:$game", status => 'turn_pick');
	$redis->hdel("game:$game", 'czar');
	return 1;
}

sub _set_next_czar {
	my ($c, $game) = @_;
	my $redis = $c->redis;
	my $players = $c->game_players($game);
	my $czar = $redis->hget("game:$game", 'czar');
	my $next_czar;
	if (defined $czar) {
		my $czar_i = first_index { $czar eq $_ } @$players;
		$czar_i = ($czar_i < 0) ? 0 : $czar_i + 1;
		$next_czar = $players->[$czar_i];
	}
	$next_czar //= $players->[0];
	$redis->hset("game:$game", czar => $next_czar);
	return $next_czar;
}

sub _set_expires {
	my ($c, $game) = @_;
	my $redis = $c->redis;
	my $players = $c->game_players($game);
	$redis->expire("game:$game" => GAME_EXPIRE_SECONDS);
	$redis->expire("game:$game:players" => GAME_EXPIRE_SECONDS);
	$redis->expire("game:$game:draw_white" => GAME_EXPIRE_SECONDS);
	$redis->expire("game:$game:draw_black" => GAME_EXPIRE_SECONDS);
	$redis->expire("game:$game:discard_white" => GAME_EXPIRE_SECONDS);
	$redis->expire("game:$game:discard_black" => GAME_EXPIRE_SECONDS);
	$redis->expire("game:$game:played_white" => GAME_EXPIRE_SECONDS);
	foreach my $player (@$players) {
		$redis->expire("game:$game:players:$player" => GAME_EXPIRE_SECONDS);
		$redis->expire("game:$game:players:$player:hand" => GAME_EXPIRE_SECONDS);
	}
}

1;

