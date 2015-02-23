function ChatMessage(date, msg) {
	var self = this;
	self.timestamp = '['+date.toLocaleTimeString()+']';
	self.message = msg;
}

function GameViewModel() {
	var self = this;
	
	self.chatLog = ko.observableArray();
	self.addChatLog = function (date, msg) {
		self.chatLog.push(new ChatMessage(date, msg));
	}
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
window.onbeforeunload = function() {
	ws.send(JSON.stringify({'action': 'leave'}));
};
setInterval(function() {
	ws.send(JSON.stringify({'action': 'heartbeat'}));
}, 10000);
function sendChat(input) { ws.send(JSON.stringify({'action': 'chat', 'msg': input.value})); input.value = '' }
function startGame(button) { ws.send(JSON.stringify({'action': 'start'})); button.disabled = true; }

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

