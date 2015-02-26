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
	
	$self->plugins->namespaces(['Game::PYX::Plugin']);
	$self->plugin('Redis');
	
	my $r = $self->routes;
	$r->get('/')->to('game#page', template => 'page');
	$r->websocket('/ws')->to('game#connect')->name('ws_connect');
}

1;

