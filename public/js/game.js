var white_cards = {};
var black_cards = {};

function ChatMessage(date, msg) {
	var self = this;
	self.timestamp = '['+date.toLocaleTimeString()+']';
	self.message = msg;
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
	
	self.chatInput = ko.observable('');
	self.sendChat = function() {
		ws_send({'action':'chat', 'msg':self.chatInput()});
		self.chatInput('');
	};
	self.chatLog = ko.observableArray();
	self.addChatLog = function (date, msg) {
		self.chatLog.push(new ChatMessage(date, msg));
	};
	
	self.canStartGame = ko.observable(true);
	self.startGame = function() {
		self.canStartGame(false);
		ws_send({'action':'start'});
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
}

var gvm = new GameViewModel();
ko.applyBindings(gvm);

var ws_url = document.getElementById('ws_url').textContent;
var ws = new WebSocket(ws_url);

ws.onmessage = function (e) {
	var data = JSON.parse(e.data);
	switch (data.action) {
	case 'game_state':
		setGameState(data.state);
		updateCardData();
		break;
	case 'card_data':
		setCardData(data.cards);
		updateCardData();
		break;
	case 'chat':
	case 'join':
	case 'leave':
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
	case 'chat':
		msg = data.from + ': ' + data.msg;
		break;
	case 'join':
		msg = data.from + ' has joined';
		break;
	case 'leave':
		msg = data.from + ' has left';
		break;
	}
	var date = new Date(data.time * 1000);
	gvm.addChatLog(date, msg);
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
