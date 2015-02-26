# PYX-Mojo
[Pretend You're Xyzzy](http://pretendyoure.xyz/zy/) is an online version of the
popular and often inappropriate party game [Cards Against Humanity](http://cardsagainsthumanity.com).
This is an implementation of the [original PYX](https://github.com/ajanata/PretendYoureXyzzy/)
using [Mojolicious](http://mojolicio.us), [WebSockets](https://developer.mozilla.org/en-US/docs/WebSockets),
and notifications through [Redis](http://redis.io/).

## Requirements
The only system requirements are:

* Perl 5.10.1+
* Redis 2.6.12+

## Installation
To install the required perl modules, run in the base directory:

`cpanm --installdeps .`

If you don't have [cpanminus](https://metacpan.org/pod/App::cpanminus), you can use this line:

`curl -L https://cpanmin.us | perl - -M https://cpan.metacpan.org --installdeps .`

## Configuration
Configuration can be specified in a file named `pyx.conf` in the base directory; see the example configuration file.
The following configuration options are recognized:

* `redis_url` - URL to access Redis database, in a format such as `redis://host:port/i` or `redis://x:password@host:port`. `i` is the database index to use. If not configured, it will connect to `redis://localhost:6379/0`.
* `secret` - Application secret to sign session cookies. Set this to any string, changing this will invalidate existing sessions.
* `hypnotoad` - This section is used directly to configure the Hypnotoad web server, see the [Hypnotoad documentation](https://metacpan.org/pod/Mojo::Server::Hypnotoad#SETTINGS) for more details.

## Running
After configuring your Redis URL if needed, load the cards into Redis:

`script/pyx_load cards.json`

Then, start the web server:

`hypnotoad script/pyx`

That's it! The application logs to `log/production.log`.
You can reload the web server by running the same command again, or stop it with the `--stop` switch.

Note: Hypnotoad is a UNIX optimized preforking server, and does not work in Windows environments.
In Windows you can run the application as a standard daemon:

`script/pyx daemon`

This daemon must be configured by environment variables, see [Mojo::Server::Daemon](https://metacpan.org/pod/Mojo::Server::Daemon#ATTRIBUTES).
