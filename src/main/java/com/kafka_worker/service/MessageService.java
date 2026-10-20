package com.kafka_worker.service;

import org.springframework.stereotype.Service;

import com.kafka_worker.messaging.MessageProducer;

@Service 
public class MessageService {
    private final MessageProducer messageProducer;

    public MessageService(MessageProducer messageProducer) {
        this.messageProducer = messageProducer;
    }

    public void processMessage(String messageId) {
        System.out.println("Processando mensagem: " + messageId);
        messageProducer.publish(messageId);
    }
}
