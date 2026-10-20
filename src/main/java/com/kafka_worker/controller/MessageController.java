package com.kafka_worker.controller;

import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

import com.kafka_worker.messaging.MessageProducer;
import com.kafka_worker.messaging.data.MessageRequest;

@RestController 
public class MessageController {

    private final MessageProducer messageProducer;

    public MessageController(MessageProducer messageProducer) {
        this.messageProducer = messageProducer;
    }

    @PostMapping("/messages")
    public ResponseEntity<String> sendMessage(@RequestBody MessageRequest request) {
        String messageId = request.messageId();
        messageProducer.publish(messageId);
        return ResponseEntity.accepted().body("Mensagem enviada com sucesso: " + messageId);
    }
}
