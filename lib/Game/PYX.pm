package Game::PYX;
use Mojo::Base 'Mojolicious';

sub startup {
	my $self = shift;
	
	$self->moniker('pyx');
	$self->plugin('Config' => { default => {} });
	my $secret = $self->config('secret');
	$self->secrets([$secret]) if defined $secret;
	
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

