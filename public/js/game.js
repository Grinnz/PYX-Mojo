var white_cards = {};
var black_cards = {};

function ChatMessage(date, msg) {
	var self = this;
	self.timestamp = '['+date.toLocaleTimeString()+']';
	self.message = msg;
}

function GameInstance(name) {
	var self = this;
	self.name = name;
	self.players = ko.observable(0);
	self.isJoinable = ko.observable(true);
	self.setFromData = function(data) {
		if (data !== null) {
			self.players(data.players);
			self.isJoinable(data.joinable);
		}
	}
}

function WhiteCard(id) {
	var self = this;
	self.id = id;
	self.text = ko.observable('');
	self.watermark = ko.observable('');
	self.setFromData = function(data) {
		if (data !== null) {
			self.text(data.text);
			self.watermark(data.watermark);
		}
	};
}

function BlackCard(id) {
	var self = this;
	self.id = id;
	self.text = ko.observable('');
	self.draw = ko.observable(0);
	self.pick = ko.observable(1);
	self.watermark = ko.observable('');
	self.setFromData = function(data) {
		if (data !== null) {
			self.text(data.text);
			self.draw(data.draw);
			self.pick(data.pick);
			self.watermark(data.watermark);
		}
	};
}

function GameViewModel() {
	var self = this;
	
	self.goToLandingPage = function() { location.hash = ''; };
	self.goToGamesLobby = function() { location.hash = 'games'; };
	self.goToGame = function(game) { location.hash = 'games/' + game; };
	self.showLandingPage = ko.observable(false);
	self.showGamesLobby = ko.observable(false);
	self.activeGame = ko.observable(null);
	
	self.nick = ko.observable(null);
	self.redirectOnNick = null;
	
	self.submitNick = function() {
		ws_send({'action':'set_nick', 'nick':self.nick()});
	};
	
	self.onNickUpdate = function(redir) {
		if (self.redirectOnNick !== null) {
			location.hash = self.redirectOnNick;
			self.redirectOnNick = null;
		} else if (redir) {
			self.goToGamesLobby();
		}
	}
	
	self.availableGames = ko.observableArray();
	self.addToGames = function(games) {
		games.forEach(function(data) {
			var game = new GameInstance(data.name);
			game.setFromData(data);
			self.availableGames.push(game);
		});
	};
	
	self.redirectOnGame = null;
	
	self.gameToCreate = ko.observable('');
	self.createGame = function() {
		ws_send({'action':'create_game', 'game':self.gameToCreate()});
	};
	self.joinGame = function(game) {
		ws_send({'action':'join_game', 'game':game.name});
	};
	
	self.chatInput = ko.observable('');
	self.sendChat = function() {
		ws_send({'action':'chat', 'game':self.activeGame(), 'msg':self.chatInput()});
		self.chatInput('');
	};
	self.chatLog = ko.observableArray();
	self.addChatLog = function (date, msg) {
		self.chatLog.push(new ChatMessage(date, msg));
	};
	
	self.canStartGame = ko.observable(true);
	self.startGame = function() {
		self.canStartGame(false);
		ws_send({'action':'start_game', 'game':self.activeGame()});
	};
	
	self.hand = ko.observableArray();
	self.addToHand = function(ids) {
		ids.forEach(function(id) { self.hand.push(new WhiteCard(id)); });
	};
	
	self.blackCard = ko.observable(null);
	self.setBlackCard = function(id) {
		if (id === null) { self.blackCard(null); }
		else { self.blackCard(new BlackCard(id)); }
	};
	
	var r = Rlite();
	// Default route
	r.add('', function() {
		document.title = 'PYX Test';
		console.log('Loading landing page');
		self.activeGame(null);
		self.showGamesLobby(false);
		self.showLandingPage(true);
	});
	
	r.add('games', function() {
		console.log('Loading games lobby');
		if (self.nick() !== null) {
			document.title = 'PYX Lobby';
			self.activeGame(null);
			self.showLandingPage(false);
			self.showGamesLobby(true);
			ws_send({'action':'game_list'});
		} else {
			self.redirectOnNick = location.hash;
			self.goToLandingPage();
		}
	});
	
	r.add('games/:name', function(r) {
		var game = r.params.name;
		console.log('Loading game ' + game);
		if (self.nick() !== null) {
			document.title = 'PYX Game ' + game;
			self.showLandingPage(false);
			self.showGamesLobby(false);
			self.activeGame(game);
		} else {
			self.redirectOnNick = location.hash;
			self.goToLandingPage();
		}
	});
	
	function processHash() {
		var hash = location.hash || '#';
		if (!r.run(hash.substr(1))) {
			// No route match
			self.goToLandingPage();
		}
	}
	
	window.addEventListener('hashchange', processHash);
	processHash();
}

var gvm = new GameViewModel();
ko.applyBindings(gvm);

var ws_url = document.getElementById('ws_url').textContent;
var ws = new WebSocket(ws_url);

ws.onopen = function (e) {
};

ws.onmessage = function (e) {
	var data = JSON.parse(e.data);
	switch (data.action) {
	case 'user_data':
		setUserData(data.user);
		break;
	case 'confirm_nick':
		if (data.confirmed) {
			gvm.nick(data.nick);
			gvm.onNickUpdate(true);
		} else {
			gvm.nickError(data.error);
		}
		break;
	case 'game_list':
		setGameList(data.games);
		break;
	case 'confirm_join':
		if (data.confirmed) {
			gvm.goToGame(data.game);
		} else {
			gvm.joinError(data.error);
		}
		break;
	case 'game_state':
		setGameState(data.state);
		updateCardData();
		break;
	case 'card_data':
		setCardData(data.cards);
		updateCardData();
		break;
	case 'user_chat':
	case 'user_join':
	case 'user_leave':
	case 'user_disconnect':
		showChat(data);
		break;
	}
};

ws.onclose = function (e) {
	gvm.addChatLog(new Date(), 'Connection closed');
};

setInterval(function() {
	ws_send({'action':'heartbeat'});
}, 10000);

function ws_send(obj) { ws.send(JSON.stringify(obj)); }

function showChat(data) {
	var msg = '';
	switch (data.action) {
	case 'user_chat':
		msg = data.from + ': ' + data.msg;
		break;
	case 'user_join':
		msg = data.from + ' has joined';
		break;
	case 'user_leave':
		msg = data.from + ' has left';
		break;
	case 'user_disconnect':
		msg = data.from + ' has disconnected';
		break;
	}
	var date = new Date(data.time * 1000);
	gvm.addChatLog(date, msg);
}

function setUserData(user) {
	if (user.nick !== null) {
		gvm.nick(user.nick);
		gvm.onNickUpdate(false);
	}
}

function setGameList(games) {
	gvm.availableGames.removeAll();
	gvm.addToGames(games);
}

function setGameState(state) {
	gvm.hand.removeAll();
	gvm.addToHand(state.hand);
	gvm.setBlackCard(state.black_card);
	updateCardData();
}

function setCardData(data) {
	for (id in data.black) {
		var card = data.black[id];
		black_cards[id] = {
			'text':card.text,
			'draw':card.draw,
			'pick':card.pick,
			'watermark':card.watermark,
		};
	}
	for (id in data.white) {
		var card = data.white[id];
		white_cards[id] = {
			'text':card.text,
			'watermark':card.watermark,
		};
	}
}

function updateCardData() {
	var ids = {'white':[], 'black':[]};
	var black_card = gvm.blackCard();
	if (black_card !== null) {
		var id = black_card.id;
		if (black_cards.hasOwnProperty(id)) {
			black_card.setFromData(black_cards[id]);
		} else {
			black_cards[id] = null;
			ids.black.push(id);
		}
	}
	gvm.hand().forEach(function(card) {
		var id = card.id;
		if (white_cards.hasOwnProperty(id)) {
			card.setFromData(white_cards[id]);
		} else {
			white_cards[id] = null;
			ids.white.push(id);
		}
	});
	if (ids.white.length > 0 || ids.black.length > 0) {
		ws_send({'action':'card_data', 'cards':ids});
	}
}
