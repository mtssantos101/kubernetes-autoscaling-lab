package com.kafka_worker.controller;

import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

import com.kafka_worker.messaging.data.MessageRequest;
import com.kafka_worker.service.MessageService;

@RestController 
public class MessageController {

    private final MessageService messageService;

    public MessageController(MessageService messageService) {
        this.messageService = messageService;
    }

    @PostMapping("/messages")
    public ResponseEntity<String> sendMessage(@RequestBody MessageRequest request) {
        messageService.processMessage(request.messageId());
        return ResponseEntity.accepted().body("Mensagem enviada com sucesso: " + request.messageId());
    }
}
