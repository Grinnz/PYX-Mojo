package Game::PYX;
use Mojo::Base 'Mojolicious';
use Mojo::Redis2;

sub startup {
	my $self = shift;
	
	$self->moniker('pyx');
	$self->plugin('Config' => { default => {
	}});
	my $secret = $self->config('secret') // 'pyx';
	$self->secrets([$secret]);
	
	$self->helper(redis => sub {
		my $c = shift;
		my $redis = $c->stash('pyx.redis');
		unless (defined $redis) {
			my $url = $c->config('redis_url');
			$c->stash('pyx.redis' => ($redis = defined $url
				? Mojo::Redis2->new(url => $url) : Mojo::Redis2->new));
		}
		return $redis;
	});
	
	my $r = $self->routes;
	$r->get('/')->to(template => 'index');
	$r->post('/' => sub {
		my $c = shift;
		my $nick = $c->param('nick') // 'Tester';
		my $game = $c->param('game') // 'test';
		$c->session->{nick} = $nick;
		$c->redirect_to("/game/$game");
	});
	$r->get('/game/:id')->to(template => 'game');
	$r->websocket('/game/:id/join')->to('game#join_game')->name('ws_join');
}

1;

