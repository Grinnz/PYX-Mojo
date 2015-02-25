package Game::PYX;
use Mojo::Base 'Mojolicious';
use Mojo::Redis2;
use Scalar::Util 'weaken';

sub startup {
	my $self = shift;
	
	$self->moniker('pyx');
	$self->plugin('Config' => { default => {
	}});
	my $secret = $self->config('secret') // 'pyx';
	$self->secrets([$secret]);
	
	my $log = $self->log;
	$SIG{__WARN__} = sub {
		my $err = shift;
		chomp $err;
		$log->warn($err);
		warn "$err\n";
	};
	
	$self->helper(redis => sub {
		my $c = shift;
		my $redis = $c->stash('pyx.redis');
		unless (defined $redis) {
			my $url = $c->config('redis_url');
			$c->stash('pyx.redis' => ($redis = defined $url
				? Mojo::Redis2->new(url => $url) : Mojo::Redis2->new));
			weaken $c;
			$redis->on(message => sub { $c->on_redis_message(@_) });
		}
		return $redis;
	});
	
	my $r = $self->routes;
	$r->get('/')->to('game#page', template => 'page');
	$r->websocket('/ws')->to('game#connect')->name('ws_connect');
}

1;

