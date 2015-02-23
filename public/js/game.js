function ChatMessage(date, msg) {
	var self = this;
	self.timestamp = '['+date.toLocaleTimeString()+']';
	self.message = msg;
}

function GameViewModel() {
	var self = this;
	
	self.chatLog = ko.observableArray();
	self.chatInput = ko.observable('');
	self.addChatLog = function (date, msg) {
		self.chatLog.push(new ChatMessage(date, msg));
	}
	
	self.canStartGame = ko.observable(true);
	self.startGame = function (form) {
		self.canStartGame(false);
		ws_send({'action':'start'});
	};
	
	self.sendChat = function (form) {
		ws_send({'action':'chat', 'msg':self.chatInput()});
		self.chatInput('');
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
		console.log(data.state);
		break;
	case 'card_data':
		console.log(data.cards);
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

