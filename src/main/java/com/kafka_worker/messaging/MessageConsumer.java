package com.kafka_worker.messaging;

import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.stereotype.Component;

@Component 
public class MessageConsumer {
    @KafkaListener(topics = "message.sended")
    public void consume(String messageId) {
        System.out.println(
                "Mensagem recebida pelo consumer: " + messageId);
    }

}
